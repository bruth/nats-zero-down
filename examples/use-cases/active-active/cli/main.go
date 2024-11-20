package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"sync"
	"time"

	"github.com/nats-io/jsm.go/natscontext"
	"github.com/nats-io/nats.go"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	var (
		urls            string
		natsContext     string
		preferredRegion string
		maxReconnects   int
		reconnectWait   time.Duration
		streamPrefix    string
	)

	flag.StringVar(&natsContext, "context", "", "NATS context.")
	flag.StringVar(&urls, "urls", "", "Regions URLs in the form of region=url,region=url.")
	flag.StringVar(&preferredRegion, "region", "", "Preferred region.")
	flag.IntVar(&maxReconnects, "max-reconnects", 3, "Maximum number of reconnects.")
	flag.DurationVar(&reconnectWait, "reconnect-wait", time.Second, "Reconnect wait time.")
	flag.StringVar(&streamPrefix, "stream", "events", "Stream name.")

	flag.Parse()

	// Parse the URLs associated with each region.
	regionsURLs := make(map[string][]string)
	var regionOrder []string
	for _, u := range strings.Split(urls, ",") {
		parts := strings.Split(u, "=")
		if len(parts) != 2 {
			return fmt.Errorf("invalid url: %s", u)
		}
		if _, ok := regionsURLs[parts[0]]; !ok {
			regionOrder = append(regionOrder, parts[0])
		}
		regionsURLs[parts[0]] = append(regionsURLs[parts[0]], parts[1])
	}

	// This is not robust, since it relies on in-memory state. One could
	// use a database or a file to store the state, but this doesn't
	// work across instances.
	// A KV would work great, but falls into the same problem that the
	// stream does in terms of lagging behind across regions.
	conSeqs := NewConsumerSeqs()

	pushMsgs := &AckMsgs{}
	pullMsgs := &AckMsgs{}

	defer func() {
		fmt.Println("Push Messages")
		fmt.Println("region\tsubject\tseq\tdata")
		for _, m := range pushMsgs.msgs {
			fmt.Printf("%s\t%s\t%d\t%s\n", m.Region, m.Subject, m.Seq, m.Data)
		}

		fmt.Println("Pull Messages")
		fmt.Println("region\tsubject\tseq\tdata")
		for _, m := range pushMsgs.msgs {
			fmt.Printf("%s\t%s\t%d\t%s\n", m.Region, m.Subject, m.Seq, m.Data)
		}
	}()

	// This simulates publishing a publisher to the stream.
	startPublishers := func(nc *nats.Conn, region string) error {
		l := log.New(os.Stdout, fmt.Sprintf("[%s] ", region), log.LstdFlags)

		js, err := nc.JetStream()
		if err != nil {
			return err
		}

		subjectPrefix := fmt.Sprintf("%s.%s", streamPrefix, region)

		l.Printf("Starting publisher to %s.>", subjectPrefix)

		// Publish messages to the stream.
		var (
			i       int
			lastSeq uint64
		)

		for {
			i++
			ack, err := js.Publish(fmt.Sprintf("%s.%d", subjectPrefix, i), []byte(fmt.Sprintf("message %d", i)))
			if err == nil {
				lastSeq = ack.Sequence
			} else {
				l.Printf("error publishing: %s, last seq was %d", err, lastSeq)
				return err
			}
			time.Sleep(200 * time.Millisecond)
		}
	}

	// Setup the consumers on the stream, relative to the region.
	// This does two things, delete existing consumers and create new ones
	// with the correct start sequence.
	setupConsumers := func(nc *nats.Conn, region string) error {
		l := log.New(os.Stdout, fmt.Sprintf("[%s] ", region), log.LstdFlags)

		js, err := nc.JetStream()
		if err != nil {
			return err
		}

		streamName := fmt.Sprintf("%s-%s", streamPrefix, region)
		l.Printf("Setting up consumers for %s", streamName)

		// Given the region, delete existing consumers. Lookup the floor sequence
		// for the consumer and re-create.
		err = js.DeleteConsumer(streamName, "push-handler")
		if err == nil {
			l.Printf("push: deleted consumer")
		} else if err != nil && !errors.Is(err, nats.ErrConsumerNotFound) {
			return fmt.Errorf("push: delete consumer: %w", err)
		}

		err = js.DeleteConsumer(streamName, "pull-handler")
		if err == nil {
			l.Printf("pull: deleted consumer")
		} else if err != nil && !errors.Is(err, nats.ErrConsumerNotFound) {
			return fmt.Errorf("pull: delete consumer: %w", err)
		}

		pushStartSeq := conSeqs.Get(streamPrefix, "push-handler")
		if pushStartSeq > 0 {
			l.Printf("push: re-creating consumer @ sequence %d", pushStartSeq+1)
		}

		pullStartSeq := conSeqs.Get(streamPrefix, "pull-handler")
		if pullStartSeq > 0 {
			l.Printf("pull: re-creating consumer @ sequence %d", pullStartSeq+1)
		}

		// Default consumer configuration.
		pushCfg := nats.ConsumerConfig{
			Name:           "push-handler",
			AckPolicy:      nats.AckExplicitPolicy,
			DeliverSubject: fmt.Sprintf("push-handler-%s", region),
			DeliverPolicy:  nats.DeliverAllPolicy,
		}

		// Override if we have a start sequence.
		if pushStartSeq > 0 {
			pushCfg.DeliverPolicy = nats.DeliverByStartSequencePolicy
			pushCfg.OptStartSeq = pushStartSeq + 1
		}

		pullCfg := nats.ConsumerConfig{
			Name:          "pull-handler",
			AckPolicy:     nats.AckExplicitPolicy,
			DeliverPolicy: nats.DeliverAllPolicy,
		}

		if pullStartSeq > 0 {
			pullCfg.DeliverPolicy = nats.DeliverByStartSequencePolicy
			pullCfg.OptStartSeq = pullStartSeq + 1
		}

		_, err = js.AddConsumer(streamName, &pushCfg)
		if err != nil {
			return fmt.Errorf("push: add consumer %s", err)
		}

		_, err = js.AddConsumer(streamName, &pullCfg)
		if err != nil {
			return fmt.Errorf("pull: add-consumer %s", err)
		}

		return nil
	}

	// This binds the subscriptions to the consumers.
	bindSubs := func(ctx context.Context, nc *nats.Conn, region string) error {
		l := log.New(os.Stdout, fmt.Sprintf("[%s] ", region), log.LstdFlags)

		js, err := nc.JetStream()
		if err != nil {
			return err
		}

		streamName := fmt.Sprintf("%s-%s", streamPrefix, region)

		var pushSub *nats.Subscription
		var lastPushSeq uint64
		var lastPullSeq uint64

		errch := make(chan error, 1)

		pushSub, err = js.SubscribeSync("", nats.Bind(streamName, "push-handler"))
		if err != nil {
			return fmt.Errorf("push: %w", err)
		}

		go func() {
			defer func() {
				pushSub.Unsubscribe()
				l.Printf("push: unsubscribed")
				l.Printf("push: last sequence was %d", lastPushSeq)
			}()

			for {
				msg, err := pushSub.NextMsgWithContext(ctx)
				if err != nil {
					if errors.Is(err, context.Canceled) {
						l.Printf("push: context canceled")
						errch <- nil
						return
					}

					errch <- fmt.Errorf("push: %w", err)
					return
				}

				md, _ := msg.Metadata()
				seq := md.Sequence.Stream

				err = msg.Ack()
				if err == nil {
					lastPushSeq = seq
					conSeqs.Set(region, streamPrefix, "push-handler", seq)
					pushMsgs.Add(region, msg.Subject, seq, msg.Data)
				} else {
					l.Printf("push: failed to ack message %d: %s", seq, err)
				}
			}
		}()

		pullSub, err := js.PullSubscribe("", "", nats.Bind(streamName, "pull-handler"))
		if err != nil {
			return fmt.Errorf("pull: %w", err)
		}

		go func() {
			defer func() {
				pullSub.Unsubscribe()
				l.Printf("pull: unsubscribed")
				l.Printf("pull: last sequence was %d", lastPullSeq)
			}()

			for {
				msgs, err := pullSub.Fetch(10, nats.Context(ctx))
				if err != nil {
					// Expected if there are no messages.
					if err == context.DeadlineExceeded || err == nats.ErrTimeout {
						continue
					}

					// If the context was canceled, we are done.
					if err == context.Canceled {
						l.Printf("pull: context canceled")
						errch <- nil
						return
					}

					// Otherwise, we have an error.
					errch <- fmt.Errorf("pull: %w", err)
					return
				}

				for _, msg := range msgs {
					md, _ := msg.Metadata()
					seq := md.Sequence.Stream

					err := msg.Ack()
					if err == nil {
						lastPullSeq = seq
						conSeqs.Set(region, streamPrefix, "pull-handler", seq)
						pullMsgs.Add(region, msg.Subject, seq, msg.Data)
					} else {
						l.Printf("pull: failed to ack message %d: %s", seq, err)
					}
				}
			}
		}()

		select {
		case err := <-errch:
			return err
		case <-ctx.Done():
			return nil
		}
	}

	appHandler := func(ctx context.Context, nc *nats.Conn, region string) error {
		if err := setupConsumers(nc, region); err != nil {
			return err
		}

		errch := make(chan error, 1)

		// Start the publishers and subscribers in the Background
		// since they are both blocking.
		go func() {
			err := startPublishers(nc, region)
			if err != nil {
				errch <- err
			}
		}()

		go func() {
			err := bindSubs(ctx, nc, region)
			if err != nil {
				errch <- err
			}
		}()

		select {
		case err := <-errch:
			return err
		case <-ctx.Done():
			return nil
		}
	}

	// TODO: is this necessary?
	failoverHandler := func(current, next string) error {
		return nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cm := &ConnManager{
		Context:         natsContext,
		RegionURLs:      regionsURLs,
		RegionOrder:     regionOrder,
		ReconnectWait:   reconnectWait,
		MaxReconnects:   maxReconnects,
		AppHandler:      appHandler,
		FailoverHandler: failoverHandler,
	}

	err := cm.Start(ctx, preferredRegion)
	if err != nil {
		return err
	}
	defer cm.Drain()

	// Wait for an interrupt.
	sigch := make(chan os.Signal, 1)
	signal.Notify(sigch, os.Interrupt)
	<-sigch

	return nil
}

func NewConsumerSeqs() *ConsumerSeqs {
	return &ConsumerSeqs{
		seqs:    make(map[[2]string]uint64),
		seqTags: make(map[[3]string]uint64),
	}
}

type ConsumerSeqs struct {
	seqs    map[[2]string]uint64
	seqTags map[[3]string]uint64
	mux     sync.Mutex
}

// Get will fetch the sequence for the consumer.
func (cs *ConsumerSeqs) Get(stream, name string) uint64 {
	cs.mux.Lock()
	defer cs.mux.Unlock()
	k := [2]string{stream, name}
	return cs.seqs[k]
}

// Set will set the sequence for the consumer.
func (cs *ConsumerSeqs) Set(region, stream, name string, seq uint64) {
	cs.mux.Lock()
	defer cs.mux.Unlock()
	k := [2]string{stream, name}
	k2 := [3]string{region, stream, name}
	cs.seqs[k] = seq
	cs.seqTags[k2] = seq
}

type AppHandler func(ctx context.Context, nc *nats.Conn, region string) error

type FailoverHandler func(currentRegion string, nextRegion string) error

type ConnManager struct {
	Context         string
	RegionURLs      map[string][]string
	RegionOrder     []string
	ReconnectWait   time.Duration
	MaxReconnects   int
	AppHandler      AppHandler
	FailoverHandler FailoverHandler

	nc  *nats.Conn
	mux sync.Mutex

	currentRegion string
}

func (cm *ConnManager) Drain() {
	cm.mux.Lock()
	defer cm.mux.Unlock()

	if cm.nc != nil {
		cm.nc.Drain()
	}
}

func (cm *ConnManager) Start(ctx context.Context, region string) error {
	if cm.nc != nil && cm.nc.IsConnected() {
		return fmt.Errorf("already started")
	}

	return cm.setupConn(ctx, region)
}

func (cm *ConnManager) setupConn(ctx context.Context, region string) error {
	l := log.New(os.Stdout, fmt.Sprintf("[%s] ", region), log.LstdFlags)

	cm.mux.Lock()
	defer cm.mux.Unlock()

	// Ensure the region is valid.
	urls, ok := cm.RegionURLs[region]
	if !ok {
		return fmt.Errorf("invalid region: %s", region)
	}

	cm.currentRegion = region

	// The context is used for shared information, but the URL is overridden for the region.
	url := strings.Join(urls, ",")
	nctx, err := natscontext.New(cm.Context, true, natscontext.WithServerURL(url))
	if err != nil {
		return err
	}

	// Setup context to cancel on disconnect.
	cctx, cancel := context.WithCancel(ctx)

	// Setup the connection for the specific region.
	var nc *nats.Conn
	nc, err = nctx.Connect(
		nats.ReconnectWait(cm.ReconnectWait),
		nats.MaxReconnects(cm.MaxReconnects),
		nats.ConnectHandler(func(nc *nats.Conn) {
			l.Printf("connected to %q", nc.ConnectedUrlRedacted())
		}),
		nats.DisconnectErrHandler(func(nc *nats.Conn, err error) {
			l.Printf("disconnected: %s", err)
			l.Printf("conn status: %s", nc.Status())
			attempts := nc.Statistics.Reconnects
			l.Printf("re-connecting after %d attempts", attempts)
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			l.Printf("reconnecting...")
			l.Printf("conn status: %s", nc.Status())
		}),
		nats.ClosedHandler(func(nc *nats.Conn) {
			l.Printf("closed")
			l.Printf("conn status: %s", nc.Status())
			l.Printf("conn error: %s", nc.LastError())

			cancel()

			// Cycle through the regions and try to connect to one of them.
			for _, r := range cm.RegionOrder {
				if r == cm.currentRegion {
					continue
				}
				err := cm.setupConn(ctx, r)
				if err == nil {
					l.Printf("Failed over to %q", r)
					break
				} else {
					l.Printf("Error failing over to %q", r)
				}
			}
		}),
	)
	if err != nil {
		cancel()
		return err
	}

	cm.nc = nc

	// Start the connect handler in the background.
	go func() {
		defer cancel()
		err := cm.AppHandler(cctx, nc, region)
		if err != nil {
			l.Printf("app handler returned: %s", err)
		}
	}()

	return nil
}

type ackMsg struct {
	Region  string
	Subject string
	Seq     uint64
	Data    string
}

type AckMsgs struct {
	msgs []*ackMsg
	mux  sync.Mutex
}

func (am *AckMsgs) Add(region string, sub string, seq uint64, data []byte) {
	am.mux.Lock()
	defer am.mux.Unlock()
	am.msgs = append(am.msgs, &ackMsg{
		Region:  region,
		Subject: sub,
		Seq:     seq,
		Data:    string(data),
	})
}
