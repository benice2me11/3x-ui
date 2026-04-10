package service

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	neturl "net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/goccy/go-yaml"
)

const (
	hysteria2BinaryPath  = "/usr/local/bin/hysteria"
	hysteria2ConfigPath  = "/etc/hysteria/config.yaml"
	hysteria2ServiceName = "hysteria2"
	hysteria2StatsListen = "127.0.0.1:9088"
)

// Hysteria2TrafficStats is a compact summary of HY2 stats API data.
type Hysteria2TrafficStats struct {
	Users   int    `json:"users"`
	Online  int    `json:"online"`
	Streams int    `json:"streams"`
	Tx      uint64 `json:"tx"`
	Rx      uint64 `json:"rx"`
}

// Hysteria2Status represents the lifecycle and runtime status of the HY2 service.
type Hysteria2Status struct {
	State     ProcessState          `json:"state"`
	ErrorMsg  string                `json:"errorMsg"`
	Version   string                `json:"version"`
	Installed bool                  `json:"installed"`
	Service   string                `json:"service"`
	Stats     Hysteria2TrafficStats `json:"stats"`
}

type Hysteria2User struct {
	Username string `json:"username"`
	Password string `json:"password"`
	Link     string `json:"link"`
	Tx       uint64 `json:"tx"`
	Rx       uint64 `json:"rx"`
	Online   int    `json:"online"`
}

type Hysteria2ShareConfig struct {
	Host         string `json:"host"`
	Port         string `json:"port"`
	SNI          string `json:"sni"`
	Insecure     bool   `json:"insecure"`
	ObfsType     string `json:"obfsType"`
	ObfsPassword string `json:"obfsPassword"`
}

type Hysteria2UsersPayload struct {
	AuthType string               `json:"authType"`
	Users    []Hysteria2User      `json:"users"`
	Share    Hysteria2ShareConfig `json:"share"`
}

type hysteria2ReleaseAsset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
}

type hysteria2Release struct {
	TagName string                  `json:"tag_name"`
	Assets  []hysteria2ReleaseAsset `json:"assets"`
}

type hysteria2Config struct {
	TrafficStats struct {
		Listen string `yaml:"listen"`
		Secret string `yaml:"secret"`
	} `yaml:"trafficStats"`
}

func (s *ServerService) GetHysteria2Status() Hysteria2Status {
	status := Hysteria2Status{
		State:     Stop,
		ErrorMsg:  "",
		Version:   "Unknown",
		Installed: false,
		Service:   hysteria2ServiceName,
		Stats:     Hysteria2TrafficStats{},
	}

	if fi, err := os.Stat(hysteria2BinaryPath); err == nil && !fi.IsDir() {
		status.Installed = true
		status.Version = getHysteria2Version(hysteria2BinaryPath)
	} else {
		status.ErrorMsg = fmt.Sprintf("binary not found: %s", hysteria2BinaryPath)
	}

	if hasSystemctl() {
		stateText, errText := getSystemdUnitState(hysteria2ServiceName)
		switch stateText {
		case "active", "activating", "reloading":
			status.State = Running
		case "failed":
			status.State = Error
		case "inactive", "deactivating":
			status.State = Stop
		default:
			status.State = Stop
		}
		if errText != "" {
			status.ErrorMsg = errText
		}
	} else {
		if status.Installed && isHysteria2ProcessRunning() {
			status.State = Running
		} else {
			status.State = Stop
		}
		if status.ErrorMsg == "" {
			status.ErrorMsg = "systemctl is not available; limited monitoring mode"
		}
	}

	if status.State == Running {
		stats, err := fetchHysteria2TrafficStats(hysteria2ConfigPath)
		if err == nil {
			status.Stats = stats
		} else if status.ErrorMsg == "" {
			status.ErrorMsg = err.Error()
		}
	}

	return status
}

func (s *ServerService) InstallHysteria2() error {
	if runtime.GOOS != "linux" {
		return fmt.Errorf("automatic HY2 install currently supports linux only")
	}
	if os.Geteuid() != 0 {
		return fmt.Errorf("root privileges are required to install HY2")
	}

	release, err := fetchHysteria2LatestRelease()
	if err != nil {
		return err
	}

	assetName := getHysteria2AssetName(runtime.GOOS, runtime.GOARCH)
	if assetName == "" {
		return fmt.Errorf("unsupported platform for HY2 install: %s/%s", runtime.GOOS, runtime.GOARCH)
	}

	assetURL := ""
	for _, asset := range release.Assets {
		if asset.Name == assetName {
			assetURL = asset.URL
			break
		}
	}
	if assetURL == "" {
		return fmt.Errorf("release asset not found for %s", assetName)
	}

	if err := downloadFile(assetURL, hysteria2BinaryPath, 0755); err != nil {
		return err
	}
	if err := ensureHysteria2ConfigFile(hysteria2ConfigPath); err != nil {
		return err
	}
	if err := ensureHysteria2SystemdUnit(hysteria2ServiceName, hysteria2BinaryPath, hysteria2ConfigPath); err != nil {
		return err
	}

	if hasSystemctl() {
		if _, err := runSystemctl("daemon-reload"); err != nil {
			return err
		}
		if _, err := runSystemctl("enable", hysteria2ServiceName); err != nil {
			return err
		}
	}
	return nil
}

func (s *ServerService) StartHysteria2Service() error {
	if !hasSystemctl() {
		return fmt.Errorf("systemctl is not available")
	}
	_, err := runSystemctl("start", hysteria2ServiceName)
	return err
}

func (s *ServerService) StopHysteria2Service() error {
	if !hasSystemctl() {
		return fmt.Errorf("systemctl is not available")
	}
	_, err := runSystemctl("stop", hysteria2ServiceName)
	return err
}

func (s *ServerService) RestartHysteria2Service() error {
	if !hasSystemctl() {
		return fmt.Errorf("systemctl is not available")
	}
	_, err := runSystemctl("restart", hysteria2ServiceName)
	return err
}

func (s *ServerService) GetHysteria2Logs(count string) []string {
	if runtime.GOOS == "windows" {
		return []string{"HY2 logs are not supported on Windows in this panel mode."}
	}
	if !hasSystemctl() {
		return []string{"systemctl/journalctl are not available on this system."}
	}

	countInt, err := strconv.Atoi(count)
	if err != nil || countInt < 1 || countInt > 10000 {
		return []string{"Invalid count parameter - must be a number between 1 and 10000"}
	}

	cmd := exec.Command("journalctl", "-u", hysteria2ServiceName, "--no-pager", "-n", strconv.Itoa(countInt))
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return []string{msg}
	}
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	if len(lines) == 1 && strings.TrimSpace(lines[0]) == "" {
		return []string{"No logs"}
	}
	return lines
}

func (s *ServerService) GetHysteria2Users(hostOverride string) (*Hysteria2UsersPayload, error) {
	cfg, err := loadHysteria2ConfigMap(hysteria2ConfigPath)
	if err != nil {
		return nil, err
	}

	auth := ensureMap(cfg, "auth")
	authType := strings.ToLower(getMapString(auth, "type"))
	if authType == "" {
		authType = "unknown"
	}

	share := buildHysteria2ShareConfig(cfg, hostOverride)
	users := make([]Hysteria2User, 0)

	if authType == "userpass" {
		userpass := ensureMap(auth, "userpass")
		usernames := make([]string, 0, len(userpass))
		for k := range userpass {
			usernames = append(usernames, k)
		}
		sort.Strings(usernames)

		trafficStats, _ := fetchHysteria2TrafficMap(hysteria2ConfigPath)
		onlineStats, _ := fetchHysteria2OnlineMap(hysteria2ConfigPath)

		for _, username := range usernames {
			password := getAnyString(userpass[username])
			users = append(users, Hysteria2User{
				Username: username,
				Password: password,
				Link:     buildHysteria2Link(share, username, password),
				Tx:       trafficStats[username].Tx,
				Rx:       trafficStats[username].Rx,
				Online:   onlineStats[username],
			})
		}
	}

	return &Hysteria2UsersPayload{
		AuthType: authType,
		Users:    users,
		Share:    share,
	}, nil
}

func (s *ServerService) EnableHysteria2Userpass() error {
	cfg, err := loadHysteria2ConfigMap(hysteria2ConfigPath)
	if err != nil {
		return err
	}

	auth := ensureMap(cfg, "auth")
	userpass := ensureMap(auth, "userpass")
	currentType := strings.ToLower(getMapString(auth, "type"))

	if currentType == "password" {
		if password := getMapString(auth, "password"); password != "" {
			username := "legacy"
			if _, exists := userpass[username]; exists {
				for i := 1; i < 1000; i++ {
					candidate := fmt.Sprintf("legacy%d", i)
					if _, ok := userpass[candidate]; !ok {
						username = candidate
						break
					}
				}
			}
			userpass[username] = password
		}
		delete(auth, "password")
	}

	auth["type"] = "userpass"
	auth["userpass"] = userpass
	cfg["auth"] = auth
	if err := saveHysteria2ConfigMap(hysteria2ConfigPath, cfg); err != nil {
		return err
	}
	return restartHysteria2IfRunning()
}

func (s *ServerService) AddHysteria2User(username, password string) error {
	username = strings.TrimSpace(username)
	password = strings.TrimSpace(password)
	if username == "" || password == "" {
		return fmt.Errorf("username and password are required")
	}

	cfg, err := loadHysteria2ConfigMap(hysteria2ConfigPath)
	if err != nil {
		return err
	}

	auth := ensureMap(cfg, "auth")
	authType := strings.ToLower(getMapString(auth, "type"))
	if authType != "userpass" {
		return fmt.Errorf("auth.type is %q; switch to userpass mode first", authType)
	}

	userpass := ensureMap(auth, "userpass")
	if _, exists := userpass[username]; exists {
		return fmt.Errorf("user %q already exists", username)
	}
	userpass[username] = password
	auth["userpass"] = userpass
	cfg["auth"] = auth
	if err := saveHysteria2ConfigMap(hysteria2ConfigPath, cfg); err != nil {
		return err
	}
	return restartHysteria2IfRunning()
}

func (s *ServerService) UpdateHysteria2User(username, password string) error {
	username = strings.TrimSpace(username)
	password = strings.TrimSpace(password)
	if username == "" || password == "" {
		return fmt.Errorf("username and password are required")
	}

	cfg, err := loadHysteria2ConfigMap(hysteria2ConfigPath)
	if err != nil {
		return err
	}

	auth := ensureMap(cfg, "auth")
	authType := strings.ToLower(getMapString(auth, "type"))
	if authType != "userpass" {
		return fmt.Errorf("auth.type is %q; switch to userpass mode first", authType)
	}

	userpass := ensureMap(auth, "userpass")
	if _, exists := userpass[username]; !exists {
		return fmt.Errorf("user %q not found", username)
	}
	userpass[username] = password
	auth["userpass"] = userpass
	cfg["auth"] = auth
	if err := saveHysteria2ConfigMap(hysteria2ConfigPath, cfg); err != nil {
		return err
	}
	return restartHysteria2IfRunning()
}

func (s *ServerService) DeleteHysteria2User(username string) error {
	username = strings.TrimSpace(username)
	if username == "" {
		return fmt.Errorf("username is required")
	}

	cfg, err := loadHysteria2ConfigMap(hysteria2ConfigPath)
	if err != nil {
		return err
	}

	auth := ensureMap(cfg, "auth")
	authType := strings.ToLower(getMapString(auth, "type"))
	if authType != "userpass" {
		return fmt.Errorf("auth.type is %q; switch to userpass mode first", authType)
	}

	userpass := ensureMap(auth, "userpass")
	if _, exists := userpass[username]; !exists {
		return fmt.Errorf("user %q not found", username)
	}
	delete(userpass, username)
	auth["userpass"] = userpass
	cfg["auth"] = auth
	if err := saveHysteria2ConfigMap(hysteria2ConfigPath, cfg); err != nil {
		return err
	}
	return restartHysteria2IfRunning()
}

func (s *ServerService) KickHysteria2Users(users []string) error {
	cleaned := make([]string, 0, len(users))
	for _, u := range users {
		u = strings.TrimSpace(u)
		if u != "" {
			cleaned = append(cleaned, u)
		}
	}
	if len(cleaned) == 0 {
		return fmt.Errorf("no users provided")
	}

	baseURL, secret := getHysteria2StatsEndpoint(hysteria2ConfigPath)
	endpoint := strings.TrimRight(baseURL, "/") + "/kick"
	body, _ := json.Marshal(cleaned)
	return doHysteria2StatsPOST(endpoint, secret, body)
}

func fetchHysteria2LatestRelease() (*hysteria2Release, error) {
	const latestURL = "https://api.github.com/repos/apernet/hysteria/releases/latest"
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(latestURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("failed to query HY2 release: %s (%s)", resp.Status, strings.TrimSpace(string(body)))
	}
	var release hysteria2Release
	if err := json.NewDecoder(resp.Body).Decode(&release); err != nil {
		return nil, err
	}
	if len(release.Assets) == 0 {
		return nil, fmt.Errorf("HY2 release has no downloadable assets")
	}
	return &release, nil
}

func getHysteria2AssetName(goos, goarch string) string {
	if goos != "linux" {
		return ""
	}
	switch goarch {
	case "amd64":
		return "hysteria-linux-amd64"
	case "386":
		return "hysteria-linux-386"
	case "arm64":
		return "hysteria-linux-arm64"
	case "arm":
		return "hysteria-linux-arm"
	case "s390x":
		return "hysteria-linux-s390x"
	case "riscv64":
		return "hysteria-linux-riscv64"
	default:
		return ""
	}
}

func downloadFile(url, dest string, mode os.FileMode) error {
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download failed: %s", resp.Status)
	}

	if err := os.MkdirAll(filepath.Dir(dest), 0755); err != nil {
		return err
	}
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(dest), "hysteria2-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpPath, mode); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, dest); err != nil {
		return err
	}
	return nil
}

func ensureHysteria2ConfigFile(configPath string) error {
	if _, err := os.Stat(configPath); err == nil {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(configPath), 0755); err != nil {
		return err
	}
	defaultConfig := `# Hysteria2 server config template for 3x-ui integration
# Edit required fields before starting the service.
listen: :443

auth:
  type: password
  password: change-me

# Option A: provide your own certificate files
# tls:
#   cert: /etc/ssl/private/fullchain.pem
#   key: /etc/ssl/private/privkey.pem

# Option B: automatic certificate management (recommended)
acme:
  domains:
    - your-domain.example
  email: admin@your-domain.example

masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com

trafficStats:
  listen: 127.0.0.1:9088
  secret: change-this-secret
`
	return os.WriteFile(configPath, []byte(defaultConfig), 0600)
}

func ensureHysteria2SystemdUnit(serviceName, binaryPath, configPath string) error {
	if runtime.GOOS != "linux" {
		return nil
	}
	unitPath := filepath.Join("/etc/systemd/system", serviceName+".service")
	content := fmt.Sprintf(`[Unit]
Description=Hysteria2 Service
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%s server -c %s
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
`, binaryPath, configPath)
	return os.WriteFile(unitPath, []byte(content), 0644)
}

func hasSystemctl() bool {
	_, err := exec.LookPath("systemctl")
	return err == nil
}

func runSystemctl(args ...string) (string, error) {
	cmd := exec.Command("systemctl", args...)
	out, err := cmd.CombinedOutput()
	text := strings.TrimSpace(string(out))
	if err != nil {
		if text == "" {
			text = err.Error()
		}
		return text, fmt.Errorf("systemctl %s failed: %s", strings.Join(args, " "), text)
	}
	return text, nil
}

func restartHysteria2IfRunning() error {
	if !hasSystemctl() {
		return nil
	}
	state, _ := getSystemdUnitState(hysteria2ServiceName)
	switch state {
	case "active", "activating", "reloading":
		_, err := runSystemctl("restart", hysteria2ServiceName)
		return err
	default:
		return nil
	}
}

func getSystemdUnitState(serviceName string) (stateText, errText string) {
	cmd := exec.Command("systemctl", "is-active", serviceName)
	out, err := cmd.CombinedOutput()
	stateText = strings.TrimSpace(string(out))
	if stateText == "" {
		stateText = "unknown"
	}
	switch stateText {
	case "active", "activating", "reloading", "inactive", "deactivating":
		return stateText, ""
	case "failed":
		return stateText, "service entered failed state"
	}
	if err != nil {
		errText = strings.TrimSpace(string(out))
		if errText == "" {
			errText = err.Error()
		}
	}
	return
}

func isHysteria2ProcessRunning() bool {
	cmd := exec.Command("pgrep", "-f", "hysteria.*server")
	if err := cmd.Run(); err == nil {
		return true
	}
	return false
}

func getHysteria2Version(binaryPath string) string {
	cmd := exec.Command(binaryPath, "version")
	out, err := cmd.CombinedOutput()
	if err != nil && len(out) == 0 {
		return "Unknown"
	}
	text := string(out)
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Version:") {
			return strings.TrimSpace(strings.TrimPrefix(line, "Version:"))
		}
	}
	line := strings.TrimSpace(strings.Split(text, "\n")[0])
	if line == "" {
		return "Unknown"
	}
	return line
}

func fetchHysteria2TrafficStats(configPath string) (Hysteria2TrafficStats, error) {
	stats := Hysteria2TrafficStats{}
	baseURL, secret := getHysteria2StatsEndpoint(configPath)

	trafficURL := strings.TrimRight(baseURL, "/") + "/traffic"
	trafficBody, err := doHysteria2StatsGET(trafficURL, secret)
	if err != nil {
		return stats, err
	}

	var traffic map[string]struct {
		Tx uint64 `json:"tx"`
		Rx uint64 `json:"rx"`
	}
	if err := json.Unmarshal(trafficBody, &traffic); err != nil {
		return stats, fmt.Errorf("failed to parse HY2 traffic stats: %w", err)
	}
	stats.Users = len(traffic)
	for _, v := range traffic {
		stats.Tx += v.Tx
		stats.Rx += v.Rx
	}

	onlineURL := strings.TrimRight(baseURL, "/") + "/online"
	if onlineBody, err := doHysteria2StatsGET(onlineURL, secret); err == nil {
		var online map[string]int
		if json.Unmarshal(onlineBody, &online) == nil {
			for _, c := range online {
				stats.Online += c
			}
		}
	}

	dumpURL := strings.TrimRight(baseURL, "/") + "/dump/streams"
	if dumpBody, err := doHysteria2StatsGET(dumpURL, secret); err == nil {
		var dump struct {
			Streams []any `json:"streams"`
		}
		if json.Unmarshal(dumpBody, &dump) == nil {
			stats.Streams = len(dump.Streams)
		}
	}

	return stats, nil
}

func getHysteria2StatsEndpoint(configPath string) (baseURL, secret string) {
	baseURL = "http://" + hysteria2StatsListen
	secret = ""

	b, err := os.ReadFile(configPath)
	if err != nil {
		return
	}

	cfg := hysteria2Config{}
	if err := yaml.Unmarshal(b, &cfg); err != nil {
		return
	}

	listen := strings.TrimSpace(cfg.TrafficStats.Listen)
	secret = strings.TrimSpace(cfg.TrafficStats.Secret)
	if listen == "" {
		return
	}

	if strings.HasPrefix(listen, "http://") || strings.HasPrefix(listen, "https://") {
		baseURL = listen
		return
	}
	if strings.HasPrefix(listen, ":") {
		baseURL = "http://127.0.0.1" + listen
		return
	}
	baseURL = "http://" + listen
	return
}

func doHysteria2StatsGET(url string, secret string) ([]byte, error) {
	client := &http.Client{Timeout: 3 * time.Second}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	if secret != "" {
		req.Header.Set("Authorization", secret)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("HY2 stats request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, fmt.Errorf("HY2 stats endpoint returned %s: %s", resp.Status, strings.TrimSpace(string(msg)))
	}
	return io.ReadAll(resp.Body)
}

func doHysteria2StatsPOST(url string, secret string, body []byte) error {
	client := &http.Client{Timeout: 3 * time.Second}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if secret != "" {
		req.Header.Set("Authorization", secret)
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("HY2 stats request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return fmt.Errorf("HY2 stats endpoint returned %s: %s", resp.Status, strings.TrimSpace(string(msg)))
	}
	return nil
}

func fetchHysteria2TrafficMap(configPath string) (map[string]struct {
	Tx uint64 `json:"tx"`
	Rx uint64 `json:"rx"`
}, error) {
	baseURL, secret := getHysteria2StatsEndpoint(configPath)
	endpoint := strings.TrimRight(baseURL, "/") + "/traffic"
	body, err := doHysteria2StatsGET(endpoint, secret)
	if err != nil {
		return nil, err
	}
	var m map[string]struct {
		Tx uint64 `json:"tx"`
		Rx uint64 `json:"rx"`
	}
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, err
	}
	return m, nil
}

func fetchHysteria2OnlineMap(configPath string) (map[string]int, error) {
	baseURL, secret := getHysteria2StatsEndpoint(configPath)
	endpoint := strings.TrimRight(baseURL, "/") + "/online"
	body, err := doHysteria2StatsGET(endpoint, secret)
	if err != nil {
		return nil, err
	}
	var m map[string]int
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, err
	}
	return m, nil
}

func loadHysteria2ConfigMap(path string) (map[string]any, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var raw any
	if err := yaml.Unmarshal(b, &raw); err != nil {
		return nil, err
	}
	normalized := normalizeYAMLValue(raw)
	cfg, ok := normalized.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("invalid HY2 config structure")
	}
	return cfg, nil
}

func saveHysteria2ConfigMap(path string, cfg map[string]any) error {
	if original, err := os.ReadFile(path); err == nil {
		_ = os.WriteFile(path+".bak", original, 0600)
	}
	b, err := yaml.Marshal(cfg)
	if err != nil {
		return err
	}
	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, b, 0600); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

func normalizeYAMLValue(v any) any {
	switch t := v.(type) {
	case map[string]any:
		m := make(map[string]any, len(t))
		for k, val := range t {
			m[k] = normalizeYAMLValue(val)
		}
		return m
	case map[interface{}]interface{}:
		m := make(map[string]any, len(t))
		for k, val := range t {
			m[fmt.Sprint(k)] = normalizeYAMLValue(val)
		}
		return m
	case []any:
		arr := make([]any, len(t))
		for i, val := range t {
			arr[i] = normalizeYAMLValue(val)
		}
		return arr
	default:
		return v
	}
}

func ensureMap(m map[string]any, key string) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	if raw, ok := m[key]; ok {
		if v, ok := normalizeYAMLValue(raw).(map[string]any); ok {
			m[key] = v
			return v
		}
	}
	v := map[string]any{}
	m[key] = v
	return v
}

func getMapString(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	return getAnyString(m[key])
}

func getAnyString(v any) string {
	if v == nil {
		return ""
	}
	switch t := v.(type) {
	case string:
		return strings.TrimSpace(t)
	case fmt.Stringer:
		return strings.TrimSpace(t.String())
	case int:
		return strconv.Itoa(t)
	case int64:
		return strconv.FormatInt(t, 10)
	case uint64:
		return strconv.FormatUint(t, 10)
	case float64:
		if t == float64(int64(t)) {
			return strconv.FormatInt(int64(t), 10)
		}
		return strconv.FormatFloat(t, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(t)
	default:
		return strings.TrimSpace(fmt.Sprint(v))
	}
}

func getMapBool(m map[string]any, key string) bool {
	if m == nil {
		return false
	}
	v, ok := m[key]
	if !ok {
		return false
	}
	switch t := v.(type) {
	case bool:
		return t
	case string:
		b, _ := strconv.ParseBool(strings.TrimSpace(t))
		return b
	default:
		return false
	}
}

func buildHysteria2ShareConfig(cfg map[string]any, hostOverride string) Hysteria2ShareConfig {
	share := Hysteria2ShareConfig{
		Host:     "",
		Port:     "443",
		SNI:      "",
		Insecure: false,
	}

	host, port := parseHysteria2Listen(getMapString(cfg, "listen"))
	share.Port = port
	if host != "" && host != "0.0.0.0" && host != "::" {
		share.Host = host
	}

	acme := ensureMap(cfg, "acme")
	if share.Host == "" {
		if domainsRaw, ok := acme["domains"]; ok {
			if domains, ok := normalizeYAMLValue(domainsRaw).([]any); ok && len(domains) > 0 {
				d := strings.TrimSpace(getAnyString(domains[0]))
				if d != "" {
					share.Host = d
				}
			}
		}
	}

	tlsCfg := ensureMap(cfg, "tls")
	share.SNI = getMapString(tlsCfg, "sni")
	if share.SNI == "" {
		share.SNI = share.Host
	}
	if share.Host == "" && share.SNI != "" {
		share.Host = share.SNI
	}
	share.Insecure = getMapBool(tlsCfg, "insecure")

	obfs := ensureMap(cfg, "obfs")
	share.ObfsType = strings.ToLower(getMapString(obfs, "type"))
	if share.ObfsType == "salamander" {
		share.ObfsPassword = getMapString(ensureMap(obfs, "salamander"), "password")
	}

	if hostOverride = strings.TrimSpace(hostOverride); hostOverride != "" {
		share.Host = hostOverride
		if share.SNI == "" {
			share.SNI = hostOverride
		}
	}
	return share
}

func parseHysteria2Listen(listen string) (host, port string) {
	listen = strings.TrimSpace(listen)
	if listen == "" {
		return "", "443"
	}
	if strings.HasPrefix(listen, ":") {
		return "", strings.TrimPrefix(listen, ":")
	}
	if h, p, err := net.SplitHostPort(listen); err == nil {
		return strings.Trim(h, "[]"), p
	}
	if strings.Count(listen, ":") == 0 {
		return listen, "443"
	}
	return listen, "443"
}

func buildHysteria2Link(share Hysteria2ShareConfig, username, password string) string {
	if strings.TrimSpace(share.Host) == "" || strings.TrimSpace(share.Port) == "" || strings.TrimSpace(password) == "" {
		return ""
	}

	values := neturl.Values{}
	if share.SNI != "" {
		values.Set("sni", share.SNI)
	}
	if share.Insecure {
		values.Set("insecure", "1")
	}
	if share.ObfsType != "" {
		values.Set("obfs", share.ObfsType)
	}
	if share.ObfsType == "salamander" && share.ObfsPassword != "" {
		values.Set("obfs-password", share.ObfsPassword)
	}

	userEscaped := neturl.PathEscape(strings.TrimSpace(username))
	passEscaped := neturl.PathEscape(strings.TrimSpace(password))
	auth := passEscaped
	if userEscaped != "" {
		// HY2 userpass URI auth format: username:password
		auth = userEscaped + ":" + passEscaped
	}
	link := fmt.Sprintf("hysteria2://%s@%s:%s", auth, share.Host, share.Port)
	if q := values.Encode(); q != "" {
		link += "/?" + q
	}
	if username != "" {
		link += "#" + neturl.QueryEscape(username)
	}
	return link
}

// GetHysteria2SubscriptionLinkByUsername builds a HY2 share link for a specific
// subscription/user id using the server-side HY2 config.
func GetHysteria2SubscriptionLinkByUsername(username, hostOverride string) (string, error) {
	username = strings.TrimSpace(username)
	if username == "" {
		return "", fmt.Errorf("username is required")
	}

	cfg, err := loadHysteria2ConfigMap(hysteria2ConfigPath)
	if err != nil {
		return "", err
	}

	share := buildHysteria2ShareConfig(cfg, hostOverride)
	auth := ensureMap(cfg, "auth")
	authType := strings.ToLower(getMapString(auth, "type"))

	switch authType {
	case "userpass":
		userpass := ensureMap(auth, "userpass")
		password := strings.TrimSpace(getAnyString(userpass[username]))
		if password == "" {
			return "", fmt.Errorf("hysteria2 user %q not found", username)
		}
		return buildHysteria2Link(share, username, password), nil
	case "password":
		password := strings.TrimSpace(getMapString(auth, "password"))
		if password == "" {
			return "", fmt.Errorf("hysteria2 auth.password is empty")
		}
		return buildHysteria2Link(share, "", password), nil
	default:
		if authType == "" {
			authType = "unknown"
		}
		return "", fmt.Errorf("unsupported hysteria2 auth.type %q", authType)
	}
}
