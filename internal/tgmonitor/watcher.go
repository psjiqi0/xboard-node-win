package tgmonitor

import (
	"bufio"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/cedar2025/xboard-node/internal/tgconfig"
)

type AlertType int

const (
	AlertSSH AlertType = iota
	AlertHTTP
	AlertHTTPS
	AlertLoginFail
	AlertUnknown
)

func (a AlertType) String() string {
	switch a {
	case AlertSSH:
		return "SSH"
	case AlertHTTP:
		return "HTTP(80)"
	case AlertHTTPS:
		return "HTTPS(443)"
	case AlertLoginFail:
		return "登录失败"
	default:
		return "未知"
	}
}

type Alert struct {
	Type      AlertType
	Message   string
	Timestamp time.Time
}

type NotifyFunc func(alert Alert)

type Watcher struct {
	cfg      *tgconfig.Config
	notifyFn NotifyFunc
	mu       sync.Mutex
	stopCh   chan struct{}
	running  bool
}

func NewWatcher(cfg *tgconfig.Config, notifyFn NotifyFunc) *Watcher {
	return &Watcher{
		cfg:      cfg,
		notifyFn: notifyFn,
		stopCh:   make(chan struct{}),
	}
}

func (w *Watcher) Start() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.running {
		return
	}
	w.running = true
	w.stopCh = make(chan struct{})
	go w.loop()
}

func (w *Watcher) Stop() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.running {
		return
	}
	w.running = false
	close(w.stopCh)
}

func (w *Watcher) loop() {
	for {
		select {
		case <-w.stopCh:
			return
		default:
		}
		if !w.cfg.MonitorOn {
			time.Sleep(5 * time.Second)
			continue
		}
		w.watchLocalLogs()
		time.Sleep(2 * time.Second)
	}
}

func (w *Watcher) watchLocalLogs() {
	cmd := exec.Command("logread", "-f")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}

	go func() {
		<-w.stopCh
		if cmd.Process != nil {
			cmd.Process.Kill()
		}
	}()

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 64*1024)
	for scanner.Scan() {
		select {
		case <-w.stopCh:
			cmd.Process.Kill()
			return
		default:
		}
		line := scanner.Text()
		alert := w.parseLine(line)
		if alert != nil && w.notifyFn != nil {
			w.notifyFn(*alert)
		}
	}
	cmd.Process.Wait()
}

func (w *Watcher) parseLine(line string) *Alert {
	lower := strings.ToLower(line)
	now := time.Now()

	if strings.Contains(lower, "dropbear") {
		if strings.Contains(lower, "password accepted") || strings.Contains(lower, "pubkey") {
			return &Alert{
				Type:      AlertSSH,
				Message:   fmt.Sprintf("SSH 登录成功: %s", line),
				Timestamp: now,
			}
		}
		if strings.Contains(lower, "failed password") || strings.Contains(lower, "authentication failure") {
			return &Alert{
				Type:      AlertLoginFail,
				Message:   fmt.Sprintf("SSH 登录失败: %s", line),
				Timestamp: now,
			}
		}
		if strings.Contains(lower, "connection closed") || strings.Contains(lower, "disconnect") {
			return &Alert{
				Type:      AlertSSH,
				Message:   fmt.Sprintf("SSH 断开: %s", line),
				Timestamp: now,
			}
		}
	}

	if strings.Contains(lower, "uhttpd") || strings.Contains(lower, "luci") {
		if strings.Contains(lower, "login") || strings.Contains(lower, "auth") {
			return &Alert{
				Type:      AlertHTTP,
				Message:   fmt.Sprintf("管理页面访问: %s", line),
				Timestamp: now,
			}
		}
	}

	if strings.Contains(lower, "80") && (strings.Contains(lower, "accept") || strings.Contains(lower, "connect")) {
		return &Alert{
			Type:      AlertHTTP,
			Message:   fmt.Sprintf("HTTP 访问: %s", line),
			Timestamp: now,
		}
	}

	if strings.Contains(lower, "443") && (strings.Contains(lower, "accept") || strings.Contains(lower, "connect")) {
		return &Alert{
			Type:      AlertHTTPS,
			Message:   fmt.Sprintf("HTTPS 访问: %s", line),
			Timestamp: now,
		}
	}

	return nil
}