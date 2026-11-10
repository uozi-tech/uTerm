// uterm-relay lets the uTerm phone app reach a Mac on another network.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"

	"uterm.local/relay/internal/relay"
)

const version = "1.3.0"

const usage = `uterm-relay %s

  uterm-relay [serve]         run the relay
  uterm-relay config          print the configuration devices import (contains the member key)
  uterm-relay config-url      print it as a uterm:// link, for a QR code
  uterm-relay status          list online hosts and connections
  uterm-relay rotate          replace the member key and drop everyone; import the new config again
  uterm-relay forget <host>   unbind a host id from its key, after that Mac was reinstalled
  uterm-relay version

Settings (environment):
  RELAY_PUBLIC_HOST   domain or IP devices connect to (required for config)
  RELAY_PUBLIC_PORT   port devices connect to (default 47310)
  RELAY_NAME          name shown in the apps
  RELAY_LISTEN        listen address (default :47310)
  RELAY_DATA          data directory (default /data)
  RELAY_RATE_PER_IP   new connections one address may open in 10 s; 0 turns it off (default 60)
`

func main() {
	command := "serve"
	if len(os.Args) > 1 {
		command = os.Args[1]
	}
	dataDir := envOr("RELAY_DATA", "/data")
	socket := relay.AdminSocketPath(dataDir)

	var err error
	switch command {
	case "serve":
		err = serve(dataDir, socket)
	case "config", "config-url":
		err = printConfig(dataDir, command == "config-url")
	case "status", "rotate":
		err = admin(socket, command)
	case "forget":
		if len(os.Args) != 3 {
			err = fmt.Errorf("forget needs a host id")
		} else {
			err = admin(socket, "forget "+os.Args[2])
		}
	case "version":
		fmt.Println(version)
	case "help", "-h", "--help":
		fmt.Printf(usage, version)
	default:
		fmt.Fprintf(os.Stderr, usage, version)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "uterm-relay: %v\n", err)
		os.Exit(1)
	}
}

func serve(dataDir, socket string) error {
	store, err := relay.OpenStore(dataDir, os.Getenv("RELAY_NAME"))
	if err != nil {
		return err
	}
	limits := relay.DefaultLimits()
	if text := os.Getenv("RELAY_RATE_PER_IP"); text != "" {
		value, err := strconv.Atoi(text)
		if err != nil {
			return fmt.Errorf("RELAY_RATE_PER_IP: %w", err)
		}
		limits.RatePerIP = value
		if value <= 0 {
			// Turned off when every connection seems to come from one address (a proxy
			// in front): counting unauthenticated slots per source would then cap them all.
			limits.UnauthedPerSource = 0
		}
	}
	server := relay.NewServer(store, limits)
	server.Version = version
	bound, err := server.Listen(envOr("RELAY_LISTEN", ":47310"))
	if err != nil {
		return err
	}
	stopAdmin, err := server.ServeAdmin(socket)
	if err != nil {
		server.Close()
		return err
	}
	defer stopAdmin()
	log.Printf("uterm-relay %s listening on TCP and UDP %s", version, bound)
	if os.Getenv("RELAY_PUBLIC_HOST") == "" {
		log.Print("RELAY_PUBLIC_HOST is not set: set it to a domain or IP that reaches this server, then run `uterm-relay config`")
	} else {
		log.Print("save the configuration with: uterm-relay config > uterm-relay.json")
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	<-signals
	server.Close()
	return nil
}

func printConfig(dataDir string, asURL bool) error {
	store, err := relay.OpenStore(dataDir, os.Getenv("RELAY_NAME"))
	if err != nil {
		return err
	}
	port, err := strconv.Atoi(envOr("RELAY_PUBLIC_PORT", "47310"))
	if err != nil {
		return fmt.Errorf("RELAY_PUBLIC_PORT: %w", err)
	}
	config, err := store.ClientConfig(os.Getenv("RELAY_PUBLIC_HOST"), port)
	if err != nil {
		return err
	}
	if asURL {
		link, err := config.URL()
		if err != nil {
			return err
		}
		fmt.Println(link)
		return nil
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(config)
}

func admin(socket, command string) error {
	answer, err := relay.AdminCommand(socket, command)
	if err != nil {
		return err
	}
	if rest, failed := strings.CutPrefix(answer, "error: "); failed {
		return fmt.Errorf("%s", rest)
	}
	fmt.Println(answer)
	return nil
}

func envOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
