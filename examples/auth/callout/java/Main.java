package example;

import io.nats.client.*;
import io.nats.client.impl.Headers;
import io.nats.jwt.*;
import io.nats.service.*;

import java.io.IOException;
import java.security.GeneralSecurityException;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;

import static io.nats.jwt.Utils.getClaimBody;

public class Main {
  static String ISSUER_NSEED = "SAANDLKMXL6CUS3CP52WIXBEDN6YJ545GDKC65U5JZPPV6WH6ESWUA6YAI";

  static final Map<String, AuthCalloutUser> NATS_USERS;

  static final NKey USER_SIGNING_KEY;
  static final String PUB_USER_SIGNING_KEY;

  static {
    try {
      USER_SIGNING_KEY = NKey.fromSeed(ISSUER_NSEED.toCharArray());
      PUB_USER_SIGNING_KEY = new String(USER_SIGNING_KEY.getPublicKey());
    }
    catch (Exception e) {
      throw new RuntimeException(e);
    }

    // This sets up a map of users to simulate a back end auth system
    //   sys/sys, SYS
    //   alice/alice, APP
    //   bob/bob, APP, pub allow "bob.>", sub allow "bob.>", response max 1
    NATS_USERS = new HashMap<>();
    NATS_USERS.put("sys", new AuthCalloutUser().userPass("sys").account("SYS"));
    NATS_USERS.put("alice", new AuthCalloutUser().userPass("alice").account("APP"));
    Permission p = new Permission().allow("bob.>");
    ResponsePermission r = new ResponsePermission().max(1);
    NATS_USERS.put("bob", new AuthCalloutUser().userPass("bob").account("APP").pub(p).sub(p).resp(r));
  }

  public static void main(String[] args) throws Exception {
    Options options = new Options.Builder()
        .server("nats://localhost:4222")
        .errorListener(new ErrorListener() {
        })
        .userInfo("auth", "auth")
        .build();

    try (Connection nc = Nats.connect(options)) {
      // endpoints can be created ahead of time
      // or created directly by the ServiceEndpoint builder.
      Endpoint endpoint = Endpoint.builder()
          .name("AuthCallbackEndpoint")
          .subject("$SYS.REQ.USER.AUTH")
          .build();

      AuthCalloutHandler handler = new AuthCalloutHandler(nc);

      ServiceEndpoint serviceEndpoint = ServiceEndpoint.builder()
          .endpoint(endpoint)
          .handler(handler)
          .build();

      // Create the service from service endpoint.
      Service acService = new ServiceBuilder()
          .connection(nc)
          .name("AuthCallbackService")
          .version("0.0.1")
          .addServiceEndpoint(serviceEndpoint)
          .build();

      System.out.println("\n" + acService);

      // ----------------------------------------------------------------------------------------------------
      // Start the services
      // ----------------------------------------------------------------------------------------------------
      CompletableFuture<Boolean> serviceStoppedFuture = acService.startService();

      Thread.sleep(20_000); // plenty of time to finish running the main.sh example script

      // a real app would likely use this future
      // serviceStoppedFuture.get();
    }
    catch (Exception e) {
      onException(e);
    }
  }

  static class AuthCalloutHandler implements ServiceMessageHandler {
    Connection nc;

    public AuthCalloutHandler(Connection nc) {
      this.nc = nc;
    }

    @Override
    public void onMessage(ServiceMessage smsg) {
      System.out.println("\nReceived Message");
      System.out.println("Subject       : " + smsg.getSubject());
      System.out.println("Headers       : " + headersToString(smsg.getHeaders()));

      try {
        // Convert the message data into a Claim
        Claim claim = new Claim(getClaimBody(smsg.getData()));
        System.out.println("Claim-Request : " + claim.toJson());

        // The Claim should contain an Authorization Request
        AuthorizationRequest ar = claim.authorizationRequest;
        if (ar == null) {
          System.err.println("Invalid Authorization Request Claim");
          return;
        }
        printJson("Auth Request  : ", ar.toJson(), "server_id", "user_nkey", "client_info", "connect_opts", "client_tls", "request_nonce");

        // Check if the user exists.
        AuthCalloutUser acUser = NATS_USERS.get(ar.connectOpts.user);
        if (acUser == null) {
          respond(smsg, ar, null, "User Not Found: " + ar.connectOpts.user);
          return;
        }
        if (!acUser.pass.equals(ar.connectOpts.pass)) {
          respond(smsg, ar, null, "Password does not match: " + acUser.pass + " != " + ar.connectOpts.pass);
          return;
        }

        UserClaim uc = new UserClaim()
            .pub(acUser.pub)
            .sub(acUser.sub)
            .resp(acUser.resp);

        String userJwt = new ClaimIssuer()
            .aud(acUser.account)
            .name(ar.connectOpts.user)
            .iss(PUB_USER_SIGNING_KEY)
            .sub(ar.userNkey)
            .nats(uc)
            .issueJwt(USER_SIGNING_KEY);

        respond(smsg, ar, userJwt, null);
      }
      catch (Exception e) {
        onException(e);
      }
    }

    static final String SPACER = "                    ";
    private void printJson(String label, String json, String... splits) {
      if (splits != null && splits.length > 0) {
        String indent = SPACER.substring(0, label.length());
        boolean first = true;
        for (String split : splits) {
          int at = json.indexOf("\"" + split + "\"");
          if (at > 0) {
            if (first) {
              first = false;
              System.out.println(label + json.substring(0, at));
            }
            else {
              System.out.println(indent + json.substring(0, at));
            }
            json = json.substring(at);
          }
        }
        System.out.println(indent + json);
      }
      else {
        System.out.println(label + json);
      }
    }

    private void respond(ServiceMessage smsg,
                         AuthorizationRequest ar,
                         String userJwt,
                         String error) throws GeneralSecurityException, IOException {

      AuthorizationResponse response = new AuthorizationResponse()
          .jwt(userJwt)
          .error(error);

      if (userJwt != null) {
        printJson("Auth Resp JWT : ", getClaimBody(userJwt), "name", "nats");
      }
      else {
        System.out.println("Auth Resp ERR : " + response.toJson());
      }

      String jwt = new ClaimIssuer()
          .aud(ar.serverId.id)
          .iss(PUB_USER_SIGNING_KEY)
          .sub(ar.userNkey)
          .nats(response)
          .issueJwt(USER_SIGNING_KEY);

      System.out.println("Claim-Response: " + getClaimBody(jwt));
      smsg.respond(nc, jwt);
    }
  }

  private static void onException(Exception e) {
    //noinspection CallToPrintStackTrace
    e.printStackTrace();
  }

  public static String headersToString(Headers h) {
    if (h == null || h.isEmpty()) {
      return "None";
    }

    boolean notFirst = false;
    StringBuilder sb = new StringBuilder("[");
    for (String key : h.keySet()) {
      if (notFirst) {
        sb.append(',');
      }
      else {
        notFirst = true;
      }
      sb.append(key).append("=").append(h.get(key));
    }
    return sb.append(']').toString();
  }

  static class AuthCalloutUser {
    public String user;
    public String pass;
    public String account;
    public Permission pub;
    public Permission sub;
    public ResponsePermission resp;

    public AuthCalloutUser userPass(String userPass) {
      this.user = userPass;
      this.pass = userPass;
      return this;
    }

    public AuthCalloutUser user(String user) {
      this.user = user;
      return this;
    }

    public AuthCalloutUser pass(String pass) {
      this.pass = pass;
      return this;
    }

    public AuthCalloutUser account(String account) {
      this.account = account;
      return this;
    }

    public AuthCalloutUser pub(Permission pub) {
      this.pub = pub;
      return this;
    }

    public AuthCalloutUser sub(Permission sub) {
      this.sub = sub;
      return this;
    }

    public AuthCalloutUser resp(ResponsePermission resp) {
      this.resp = resp;
      return this;
    }
  }
}

