//go:build linux

// fc-init is a minimal init process for Firecracker microVMs.
//
// This source is mirrored from:
//
//	github.com/artemnikitin/firework/cmd/fc-init
//
// It is vendored here so image-build CI can compile fc-init even when
// the firework repository is private and no release asset is configured.
package main

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
)

const (
	runtimeMetadataPath = "/etc/firework/runtime.json"

	vmMaxMapCountPath  = "/proc/sys/vm/max_map_count"
	vmMaxMapCountValue = "262144"
	minNoFileLimit     = 65535

	kibanaUUIDPath            = "/usr/share/kibana/data/uuid"
	elasticsearchKeystorePath = "/usr/share/elasticsearch/config/elasticsearch.keystore"
)

type runtimeMetadata struct {
	User          string            `json:"user,omitempty"`
	Workdir       string            `json:"workdir,omitempty"`
	Env           map[string]string `json:"env,omitempty"`
	WritablePaths []string          `json:"writable_paths,omitempty"`
}

func main() {
	mountAll()
	setHostname()
	applyRuntimeTuning()
	meta := loadRuntimeMetadata()
	applyImageEnv(meta.Env)
	exportFireworkEnv()
	execService(meta)
}

func mountAll() {
	mounts := []struct{ fstype, src, dst, opts string }{
		{"proc", "proc", "/proc", ""},
		{"sysfs", "sys", "/sys", ""},
		{"devtmpfs", "dev", "/dev", ""},
		{"devpts", "devpts", "/dev/pts", ""},
		{"tmpfs", "tmpfs", "/run", ""},
		{"tmpfs", "tmpfs", "/tmp", ""},
	}
	for _, m := range mounts {
		_ = os.MkdirAll(m.dst, 0o755)
		if err := syscall.Mount(m.src, m.dst, m.fstype, 0, m.opts); err != nil {
			fmt.Fprintf(os.Stderr, "fc-init: mount %s: %v\n", m.dst, err)
		}
	}
}

func setHostname() {
	hostname := "fc-guest"
	if data, err := os.ReadFile("/etc/hostname"); err == nil {
		if h := strings.TrimSpace(string(data)); h != "" {
			hostname = h
		}
	}
	if err := syscall.Sethostname([]byte(hostname)); err != nil {
		fmt.Fprintf(os.Stderr, "fc-init: sethostname %s: %v\n", hostname, err)
	}
}

func loadRuntimeMetadata() runtimeMetadata {
	var meta runtimeMetadata
	data, err := os.ReadFile(runtimeMetadataPath)
	if err != nil {
		if !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "fc-init: read %s: %v\n", runtimeMetadataPath, err)
		}
		return meta
	}
	if err := json.Unmarshal(data, &meta); err != nil {
		fmt.Fprintf(os.Stderr, "fc-init: parse %s: %v\n", runtimeMetadataPath, err)
	}
	return meta
}

func applyImageEnv(env map[string]string) {
	if len(env) == 0 {
		return
	}
	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if err := os.Setenv(k, env[k]); err != nil {
			fmt.Fprintf(os.Stderr, "fc-init: set image env %s: %v\n", k, err)
		}
	}
}

func exportFireworkEnv() {
	data, err := os.ReadFile("/proc/cmdline")
	if err != nil {
		fmt.Fprintf(os.Stderr, "fc-init: read /proc/cmdline: %v\n", err)
		return
	}
	for _, arg := range strings.Fields(string(data)) {
		rest, ok := strings.CutPrefix(arg, "firework.env.")
		if !ok {
			continue
		}
		key, val, found := strings.Cut(rest, "=")
		if !found {
			continue
		}
		if err := os.Setenv(key, val); err != nil {
			fmt.Fprintf(os.Stderr, "fc-init: setenv %s: %v\n", key, err)
		}
	}
}

func execService(meta runtimeMetadata) {
	argv := os.Args[1:]
	if len(argv) == 0 {
		argv = []string{"/sbin/init"}
	}

	sanitizeRuntimeState()

	if meta.Workdir != "" {
		if err := os.Chdir(meta.Workdir); err != nil {
			fmt.Fprintf(os.Stderr, "fc-init: chdir %s: %v\n", meta.Workdir, err)
		}
	}

	if spec := strings.TrimSpace(meta.User); spec != "" {
		if err := applyUserSpec(spec, meta.WritablePaths); err != nil {
			fmt.Fprintf(os.Stderr, "fc-init: apply user %q: %v\n", spec, err)
			os.Exit(1)
		}
	}

	bin := resolveBinary(argv[0])
	if err := syscall.Exec(bin, argv, os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "fc-init: exec %s: %v\n", bin, err)
		os.Exit(1)
	}
}

func resolveBinary(bin string) string {
	if strings.HasPrefix(bin, "/") {
		return bin
	}
	paths := []string{"/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"}
	for _, dir := range paths {
		candidate := dir + "/" + bin
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return bin
}

func applyUserSpec(spec string, writablePaths []string) error {
	uid, gid, username, home, err := resolveUserSpec(spec)
	if err != nil {
		return err
	}
	if err := ensureWritablePaths(writablePaths, uid, gid); err != nil {
		return err
	}
	if home != "" {
		_ = os.Setenv("HOME", home)
	}
	if username != "" {
		_ = os.Setenv("USER", username)
	}
	if err := syscall.Setgroups([]int{gid}); err != nil {
		return fmt.Errorf("setgroups: %w", err)
	}
	if err := syscall.Setgid(gid); err != nil {
		return fmt.Errorf("setgid(%d): %w", gid, err)
	}
	if err := syscall.Setuid(uid); err != nil {
		return fmt.Errorf("setuid(%d): %w", uid, err)
	}
	return nil
}

func ensureWritablePaths(paths []string, uid, gid int) error {
	var errs []string
	for _, path := range normalizeWritablePaths(paths) {
		if err := chownPathRecursive(path, uid, gid); err != nil {
			if os.IsNotExist(err) {
				continue
			}
			errs = append(errs, fmt.Sprintf("%s: %v", path, err))
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("prepare writable paths: %s", strings.Join(errs, "; "))
	}
	return nil
}

func chownPathRecursive(path string, uid, gid int) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return os.Lchown(path, uid, gid)
	}

	return filepath.WalkDir(path, func(p string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		return os.Lchown(p, uid, gid)
	})
}

func normalizeWritablePaths(paths []string) []string {
	seen := make(map[string]struct{}, len(paths))
	out := make([]string, 0, len(paths))
	for _, p := range paths {
		p = strings.TrimSpace(p)
		if p == "" || !strings.HasPrefix(p, "/") {
			continue
		}
		p = filepath.Clean(p)
		if _, ok := seen[p]; ok {
			continue
		}
		seen[p] = struct{}{}
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

func resolveUserSpec(spec string) (uid, gid int, username, home string, err error) {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return 0, 0, "", "", fmt.Errorf("empty user spec")
	}

	userPart, groupPart, hasGroup := strings.Cut(spec, ":")
	if userPart == "" {
		return 0, 0, "", "", fmt.Errorf("invalid user spec %q", spec)
	}

	parsedUID, uidIsNumeric, err := parseNumericID(userPart)
	if err != nil {
		return 0, 0, "", "", err
	}
	if uidIsNumeric {
		uid = parsedUID
		gid = parsedUID
	} else {
		u, lookupErr := user.Lookup(userPart)
		if lookupErr != nil {
			return 0, 0, "", "", fmt.Errorf("lookup user %q: %w", userPart, lookupErr)
		}
		uid, err = parseRequiredID(u.Uid)
		if err != nil {
			return 0, 0, "", "", fmt.Errorf("invalid uid for %q: %w", userPart, err)
		}
		gid, err = parseRequiredID(u.Gid)
		if err != nil {
			return 0, 0, "", "", fmt.Errorf("invalid gid for %q: %w", userPart, err)
		}
		username = u.Username
		home = u.HomeDir
	}

	if hasGroup && groupPart != "" {
		parsedGID, gidIsNumeric, err := parseNumericID(groupPart)
		if err != nil {
			return 0, 0, "", "", err
		}
		if gidIsNumeric {
			gid = parsedGID
		} else {
			g, lookupErr := user.LookupGroup(groupPart)
			if lookupErr != nil {
				return 0, 0, "", "", fmt.Errorf("lookup group %q: %w", groupPart, lookupErr)
			}
			gid, err = parseRequiredID(g.Gid)
			if err != nil {
				return 0, 0, "", "", fmt.Errorf("invalid gid for group %q: %w", groupPart, err)
			}
		}
	}

	return uid, gid, username, home, nil
}

func parseNumericID(s string) (int, bool, error) {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, false, nil
	}
	if n < 0 {
		return 0, false, fmt.Errorf("invalid negative id %q", s)
	}
	return n, true, nil
}

func parseRequiredID(s string) (int, error) {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, fmt.Errorf("parse %q: %w", s, err)
	}
	if n < 0 {
		return 0, fmt.Errorf("negative id %d", n)
	}
	return n, nil
}

func applyRuntimeTuning() {
	if err := os.WriteFile(vmMaxMapCountPath, []byte(vmMaxMapCountValue), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "fc-init: set vm.max_map_count=%s: %v\n", vmMaxMapCountValue, err)
	}
	if err := ensureNoFileLimit(minNoFileLimit); err != nil {
		fmt.Fprintf(os.Stderr, "fc-init: set nofile limit: %v\n", err)
	}
}

func ensureNoFileLimit(min uint64) error {
	var lim syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &lim); err != nil {
		return fmt.Errorf("getrlimit: %w", err)
	}

	newCur := lim.Cur
	newMax := lim.Max
	if newCur < min {
		newCur = min
	}
	if newMax < min {
		newMax = min
	}
	if newCur == lim.Cur && newMax == lim.Max {
		return nil
	}

	if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &syscall.Rlimit{
		Cur: newCur,
		Max: newMax,
	}); err != nil {
		return fmt.Errorf("setrlimit: %w", err)
	}
	return nil
}

func sanitizeRuntimeState() {
	sanitizeKibanaUUID(kibanaUUIDPath)
	sanitizeElasticsearchKeystore(elasticsearchKeystorePath)
}

func sanitizeKibanaUUID(path string) {
	data, ok := readSmallFile(path)
	if !ok {
		return
	}
	uuid := strings.TrimSpace(string(data))
	if uuid == "" || !isValidUUID(uuid) {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "fc-init: remove invalid kibana uuid %s: %v\n", path, err)
			return
		}
		fmt.Fprintf(os.Stderr, "fc-init: removed invalid kibana uuid file %s\n", path)
	}
}

func sanitizeElasticsearchKeystore(path string) {
	info, err := os.Stat(path)
	if err != nil {
		if !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "fc-init: stat %s: %v\n", path, err)
		}
		return
	}
	if !info.Mode().IsRegular() {
		return
	}
	// Elasticsearch expects a non-empty keystore file. Size < 16 strongly
	// indicates corruption (e.g. zero-byte files observed in crash loops).
	if info.Size() >= 16 {
		return
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		fmt.Fprintf(os.Stderr, "fc-init: remove invalid elasticsearch keystore %s: %v\n", path, err)
		return
	}
	fmt.Fprintf(os.Stderr, "fc-init: removed invalid elasticsearch keystore %s\n", path)
}

func readSmallFile(path string) ([]byte, bool) {
	info, err := os.Stat(path)
	if err != nil {
		if !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "fc-init: stat %s: %v\n", path, err)
		}
		return nil, false
	}
	if !info.Mode().IsRegular() {
		return nil, false
	}
	if info.Size() > 1024 {
		fmt.Fprintf(os.Stderr, "fc-init: %s too large for UUID file\n", path)
		return nil, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "fc-init: read %s: %v\n", path, err)
		return nil, false
	}
	return data, true
}

func isValidUUID(v string) bool {
	if len(v) != 36 {
		return false
	}
	for i := 0; i < len(v); i++ {
		c := v[i]
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			if !isHex(c) {
				return false
			}
		}
	}
	return true
}

func isHex(c byte) bool {
	return ('0' <= c && c <= '9') || ('a' <= c && c <= 'f') || ('A' <= c && c <= 'F')
}
