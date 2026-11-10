package relay

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"sync"
	"syscall"
	"time"
)

// revocationLimit bounds revoked.json. Entries leave on their own when the revoked certificate expires
// (at most certMaxLifetime ahead), so this is only reached by thousands of revocations inside that
// window. Past it the entry closest to expiring goes. Only a host can add entries.
const revocationLimit = 4096

// ClientConfig is the file devices import. It holds the member private key.
type ClientConfig struct {
	Format  string `json:"format"`
	Version int    `json:"version"`
	Name    string `json:"name"`
	Host    string `json:"host"`
	Port    int    `json:"port"`
	RelayID string `json:"relayID"`
	Key     string `json:"key"`
}

// URL is the same configuration as a QR-code payload.
func (c ClientConfig) URL() (string, error) {
	raw, err := base64.StdEncoding.DecodeString(c.Key)
	if err != nil {
		return "", err
	}
	query := url.Values{}
	query.Set("v", strconv.Itoa(c.Version))
	query.Set("n", c.Name)
	query.Set("h", c.Host)
	query.Set("p", strconv.Itoa(c.Port))
	query.Set("i", c.RelayID)
	query.Set("k", base64.RawURLEncoding.EncodeToString(raw))
	return "uterm://relay?" + query.Encode(), nil
}

type relayFile struct {
	RelayID   string `json:"relayID"`
	Name      string `json:"name"`
	PublicKey string `json:"publicKey"`
}

// Store is the relay's data directory.
type Store struct {
	dir string
	mu  sync.Mutex

	relayID string
	name    string
	public  *ecdsa.PublicKey
	hosts   map[string]string
	// revoked maps a member public key the hosts have withdrawn to when (Unix seconds).
	revoked map[string]int64
}

func OpenStore(dir, name string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	// MkdirAll leaves an existing directory as it was, e.g. a volume created
	// 0755 by an older image. Nobody else needs to list where the key lives.
	if info, err := os.Stat(dir); err == nil && info.Mode().Perm()&0o077 != 0 {
		if err := os.Chmod(dir, info.Mode().Perm()&0o700); err != nil {
			log.Printf("uterm-relay: %s is readable by others and can't be tightened: %v", dir, err)
		}
	}
	store := &Store{dir: dir, name: name, hosts: map[string]string{}, revoked: map[string]int64{}}
	unlock, err := store.lockFiles()
	if err != nil {
		return nil, err
	}
	err = store.loadOrCreate()
	unlock()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(store.hostsPath())
	switch {
	case err == nil:
		if err := json.Unmarshal(data, &store.hosts); err != nil {
			return nil, fmt.Errorf("hosts.json: %w", err)
		}
	case !errors.Is(err, os.ErrNotExist):
		return nil, err
	}
	data, err = os.ReadFile(store.revokedPath())
	switch {
	case err == nil:
		if err := json.Unmarshal(data, &store.revoked); err != nil {
			return nil, fmt.Errorf("revoked.json: %w", err)
		}
		store.pruneRevokedLocked(time.Now().Unix())
	case !errors.Is(err, os.ErrNotExist):
		return nil, err
	}
	return store, nil
}

func (s *Store) relayPath() string   { return filepath.Join(s.dir, "relay.json") }
func (s *Store) hostsPath() string   { return filepath.Join(s.dir, "hosts.json") }
func (s *Store) revokedPath() string { return filepath.Join(s.dir, "revoked.json") }
func (s *Store) configPath() string  { return filepath.Join(s.dir, "member.key") }

// lockFiles keeps other processes out while the key files change. `serve` and `config` often start together
// (`docker compose up -d`, then `exec … config`); without it each generates a key and the exported
// configuration does not match the one the server checks.
func (s *Store) lockFiles() (func(), error) {
	file, err := os.OpenFile(filepath.Join(s.dir, "store.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX); err != nil {
		file.Close()
		return nil, err
	}
	// Closing the file releases the lock.
	return func() { file.Close() }, nil
}

func (s *Store) loadOrCreate() error {
	data, err := os.ReadFile(s.relayPath())
	if errors.Is(err, os.ErrNotExist) {
		return s.generate()
	}
	if err != nil {
		return err
	}
	var file relayFile
	if err := json.Unmarshal(data, &file); err != nil {
		return fmt.Errorf("relay.json: %w", err)
	}
	public, err := parsePublicKey(file.PublicKey)
	if err != nil {
		return fmt.Errorf("relay.json: %w", err)
	}
	s.relayID, s.public = file.RelayID, public
	if s.name == "" {
		s.name = file.Name
	}
	return nil
}

// generate makes a new member key. The private half only ever goes to member.key.
func (s *Store) generate() error {
	private, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	public, err := ecdsaPublicKey(private)
	if err != nil {
		return err
	}
	encoded, err := encodePublicKey(public)
	if err != nil {
		return err
	}
	relayID := hex.EncodeToString(randomBytes(8))
	body, err := json.MarshalIndent(relayFile{RelayID: relayID, Name: s.name, PublicKey: encoded}, "", "  ")
	if err != nil {
		return err
	}
	key := base64.StdEncoding.EncodeToString(private.Bytes())
	if err := writeAtomic(s.configPath(), []byte(key), 0o600); err != nil {
		return err
	}
	if err := writeAtomic(s.relayPath(), body, 0o644); err != nil {
		return err
	}
	s.relayID, s.public = relayID, public
	return nil
}

func ecdsaPublicKey(private *ecdh.PrivateKey) (*ecdsa.PublicKey, error) {
	return ecdsa.ParseUncompressedPublicKey(elliptic.P256(), private.PublicKey().Bytes())
}

func writeAtomic(path string, data []byte, mode os.FileMode) error {
	temp := path + ".tmp"
	if err := os.WriteFile(temp, data, mode); err != nil {
		return err
	}
	return os.Rename(temp, path)
}

// Identity is what the server needs to check members.
func (s *Store) Identity() (string, *ecdsa.PublicKey) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.relayID, s.public
}

// ClientConfig builds the importable configuration.
func (s *Store) ClientConfig(host string, port int) (ClientConfig, error) {
	if host == "" {
		return ClientConfig{}, errors.New("RELAY_PUBLIC_HOST is not set: devices need a domain or IP that reaches this relay")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key, err := os.ReadFile(s.configPath())
	if err != nil {
		return ClientConfig{}, fmt.Errorf("member key unavailable (run `rotate` to make a new one): %w", err)
	}
	name := s.name
	if name == "" {
		name = host
	}
	return ClientConfig{Format: "uterm-relay", Version: 1, Name: name, Host: host, Port: port,
		RelayID: s.relayID, Key: string(key)}, nil
}

// Rotate replaces the member key and forgets every host binding.
func (s *Store) Rotate() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	unlock, err := s.lockFiles()
	if err != nil {
		return err
	}
	defer unlock()
	if err := s.generate(); err != nil {
		return err
	}
	s.hosts = map[string]string{}
	// Certificates die with the key that signed them; nothing left to revoke.
	s.revoked = map[string]int64{}
	if err := s.saveRevokedLocked(); err != nil {
		return err
	}
	return s.saveHostsLocked()
}

// errBindingsFull means hosts.json already holds the most bindings the relay keeps.
var errBindingsFull = errors.New("host bindings are full")

// BindHost records hostID → key the first time and checks it afterwards. Every member shares one key,
// so without a limit any of them could grow hosts.json forever with made-up host IDs. A full store still
// checks the IDs it already holds; new ones fail with errBindingsFull until `forget` frees a slot.
func (s *Store) BindHost(hostID, key string, limit int) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if bound, ok := s.hosts[hostID]; ok {
		return bound == key, nil
	}
	if len(s.hosts) >= limit {
		return false, errBindingsFull
	}
	s.hosts[hostID] = key
	return true, s.saveHostsLocked()
}

// Forget unbinds a host that was reinstalled or lost its key.
func (s *Store) Forget(hostID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.hosts, hostID)
	return s.saveHostsLocked()
}

func (s *Store) saveHostsLocked() error {
	body, err := json.MarshalIndent(s.hosts, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(s.hostsPath(), body, 0o644)
}

// Revoke withdraws a member key that a certificate let in, until its certificate expires (Unix seconds).
// Revoking again keeps the later expiry: a host may have renewed the certificate in between.
func (s *Store) Revoke(member string, expires int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now().Unix()
	s.pruneRevokedLocked(now)
	if expires <= now {
		// Already expired: the certificate can't be used anyway.
		return nil
	}
	if current, ok := s.revoked[member]; ok && current >= expires {
		return nil
	}
	s.revoked[member] = expires
	if len(s.revoked) > revocationLimit {
		type entry struct {
			key     string
			expires int64
		}
		entries := make([]entry, 0, len(s.revoked))
		for key, when := range s.revoked {
			entries = append(entries, entry{key, when})
		}
		// The one just added always survives; of the rest, the closest to expiring goes first.
		sort.Slice(entries, func(i, j int) bool {
			if (entries[i].key == member) != (entries[j].key == member) {
				return entries[j].key == member
			}
			if entries[i].expires != entries[j].expires {
				return entries[i].expires < entries[j].expires
			}
			return entries[i].key < entries[j].key
		})
		for _, old := range entries[:len(entries)-revocationLimit] {
			delete(s.revoked, old.key)
		}
	}
	return s.saveRevokedLocked()
}

// pruneRevokedLocked drops revocations whose certificate has expired: the relay refuses it anyway.
// revoked.json from 1.2.x stored revocation times rather than expiries, so those entries go at once,
// which is right: 1.2.x certificates carry no expiry and are no longer accepted at all.
func (s *Store) pruneRevokedLocked(now int64) {
	for key, expires := range s.revoked {
		if expires <= now {
			delete(s.revoked, key)
		}
	}
}

// IsRevoked reports whether a host withdrew this member key.
func (s *Store) IsRevoked(member string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	expires, ok := s.revoked[member]
	return ok && expires > time.Now().Unix()
}

func (s *Store) saveRevokedLocked() error {
	body, err := json.MarshalIndent(s.revoked, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(s.revokedPath(), body, 0o644)
}
