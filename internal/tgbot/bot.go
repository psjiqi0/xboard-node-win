package tgbot

import (
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	"github.com/cedar2025/xboard-node/internal/localx"
	"github.com/cedar2025/xboard-node/internal/tgconfig"
	"github.com/cedar2025/xboard-node/internal/tgmonitor"
)

const maxOutput = 3500

type Bot struct {
	api       *tgbotapi.BotAPI
	cfg       *tgconfig.Config
	monitor   *tgmonitor.Watcher
	sessions  map[int64]*Session
	sessionsMu sync.RWMutex
}

type Session struct {
	State string
	Dir   string
}

func NewBot(cfg *tgconfig.Config) (*Bot, error) {
	api, err := tgbotapi.NewBotAPI(cfg.BotToken)
	if err != nil {
		return nil, fmt.Errorf("Telegram Bot 初始化失败: %w", err)
	}

	b := &Bot{
		api:      api,
		cfg:      cfg,
		sessions: make(map[int64]*Session),
	}

	b.monitor = tgmonitor.NewWatcher(cfg, b.onAlert)

	log.Printf("Bot 已启动: @%s", api.Self.UserName)
	return b, nil
}

func (b *Bot) Start() {
	b.monitor.Start()
	u := tgbotapi.NewUpdate(0)
	u.Timeout = 60
	updates := b.api.GetUpdatesChan(u)

	for update := range updates {
		if update.Message != nil {
			b.handleMessage(update.Message)
		}
	}
}

func (b *Bot) Stop() {
	b.monitor.Stop()
}

func (b *Bot) onAlert(alert tgmonitor.Alert) {
	chatID := b.cfg.ChatID
	if chatID == 0 {
		return
	}

	icon := "ℹ️"
	switch alert.Type {
	case tgmonitor.AlertSSH:
		icon = "🔑"
	case tgmonitor.AlertHTTP, tgmonitor.AlertHTTPS:
		icon = "🌐"
	case tgmonitor.AlertLoginFail:
		icon = "⚠️"
	}

	text := fmt.Sprintf("%s *[%s]*\n`%s`", icon, alert.Type, alert.Message)
	m := tgbotapi.NewMessage(chatID, text)
	m.ParseMode = "Markdown"
	b.api.Send(m)
}

func (b *Bot) handleMessage(msg *tgbotapi.Message) {
	userID := msg.From.ID

	if !b.cfg.IsEnabled() {
		b.reply(msg, "🔒 机器人未启用。请在 config.json 中配置 chat_id 和 allowed_users。")
		return
	}

	if !b.cfg.IsAllowed(userID) {
		b.reply(msg, "⚠️ 您没有权限使用此机器人")
		return
	}

	if msg.IsCommand() {
		b.handleCommand(msg)
		return
	}

	b.handleSession(msg)
}

func (b *Bot) handleCommand(msg *tgbotapi.Message) {
	switch msg.Command() {
	case "start":
		b.cmdStart(msg)
	case "exec":
		b.cmdExec(msg)
	case "shell":
		b.cmdShell(msg)
	case "exit":
		b.endShell(msg)
	case "monitor":
		b.cmdMonitor(msg)
	case "log":
		b.cmdLog(msg)
	case "status":
		b.cmdStatus(msg)
	case "help":
		b.cmdHelp(msg)
	default:
		b.reply(msg, "未知命令，发送 /help 查看帮助")
	}
}

func (b *Bot) cmdStart(msg *tgbotapi.Message) {
	text := `🤖 *本机控制机器人*

直接控制这台路由器，无需账号密码。

📋 *命令:*
/exec <命令> - 在当前工作目录执行命令
/shell - 进入交互式 Shell
/exit - 退出 Shell
/log - 查看系统日志
/status - 查看系统状态
/monitor on|off - 开关访问监控
/help - 详细帮助

发送 /shell 开始交互式操作。`
	b.reply(msg, text, "Markdown")
}

func (b *Bot) cmdHelp(msg *tgbotapi.Message) {
	text := `📖 *命令帮助*

/exec <命令> - 执行一次命令，如: /exec ls -l /etc
/shell - 进入交互式 Shell，之后直接发送命令即可执行，支持 cd 保持目录
/exit - 退出交互式 Shell
/log - 查看最近系统访问日志
/status - 查看 CPU/内存/负载/网络状态
/monitor on - 开启访问监控报警 (80/443/SSH)
/monitor off - 关闭访问监控报警`
	b.reply(msg, text, "Markdown")
}

func (b *Bot) cmdExec(msg *tgbotapi.Message) {
	cmd := msg.CommandArguments()
	if cmd == "" {
		b.reply(msg, "用法: /exec <命令>\n示例: /exec uname -a")
		return
	}

	dir := b.sessionDir(msg.From.ID)
	b.audit(msg.From.ID, "exec", cmd, dir)
	b.reply(msg, fmt.Sprintf("⚙️ `%s`", dirToString(dir, cmd)))

	output, err := localx.Exec(cmd, dir)
	if err != nil {
		b.reply(msg, fmt.Sprintf("❌ %s\n```\n%s```", err.Error(), truncate(output)), "Markdown")
		return
	}
	if output == "" {
		output = "(无输出)"
	}
	b.reply(msg, fmt.Sprintf("```\n%s```", truncate(output)), "Markdown")
}

func (b *Bot) cmdShell(msg *tgbotapi.Message) {
	if msg.Chat.Type != "private" {
		b.reply(msg, "🚫 /shell 仅允许在私聊中使用，防止命令泄露到群聊")
		return
	}
	dir, err := os.Getwd()
	if err != nil {
		dir = "/"
	}
	b.sessionsMu.Lock()
	b.sessions[msg.From.ID] = &Session{State: "shell", Dir: dir}
	b.sessionsMu.Unlock()

	b.reply(msg, fmt.Sprintf("🔌 已进入交互式 Shell（当前目录 *%s*）\n直接发送命令执行，发送 /exit 退出。", dir), "Markdown")
}

func (b *Bot) endShell(msg *tgbotapi.Message) {
	if b.clearSession(msg.From.ID) {
		b.reply(msg, "✅ 已退出 Shell")
	} else {
		b.reply(msg, "当前不在 Shell 模式")
	}
}

func (b *Bot) cmdMonitor(msg *tgbotapi.Message) {
	args := strings.ToLower(msg.CommandArguments())
	switch args {
	case "on":
		b.cfg.MonitorOn = true
		b.cfg.Save()
		b.reply(msg, "✅ 访问监控已开启")
	case "off":
		b.cfg.MonitorOn = false
		b.cfg.Save()
		b.reply(msg, "⏹ 访问监控已关闭")
	default:
		status := "开启"
		if !b.cfg.MonitorOn {
			status = "关闭"
		}
		b.reply(msg, fmt.Sprintf("当前监控状态: %s\n用法: /monitor on|off", status))
	}
}

func (b *Bot) cmdLog(msg *tgbotapi.Message) {
	output, err := localx.Exec("logread -l 30 | grep -iE 'dropbear|uhttpd|luci|http|ssh|login|auth'", "/")
	if err != nil {
		b.reply(msg, fmt.Sprintf("❌ 获取日志失败: %s", err.Error()))
		return
	}
	if output == "" {
		output = "(无日志)"
	}
	b.reply(msg, fmt.Sprintf("📜 *本机访问日志:*\n```\n%s```", truncate(output)), "Markdown")
}

func (b *Bot) cmdStatus(msg *tgbotapi.Message) {
	script := `
echo "===== 系统 ====="
uname -a
echo ""
echo "===== 负载 & 运行时间 ====="
uptime
echo ""
echo "===== 内存 ====="
free -m
echo ""
echo "===== 磁盘 (/overlay) ====="
df -h /overlay | tail -1
echo ""
echo "===== IP 地址 ====="
ip -4 addr show | grep -E 'inet ' | grep -v 127.0.0.1 | awk '{print $NF": "$2}'
`
	output, err := localx.Exec(script, "/")
	if err != nil {
		b.reply(msg, fmt.Sprintf("❌ %s", err.Error()))
		return
	}
	b.reply(msg, fmt.Sprintf("📊 *路由器状态*\n```\n%s```", truncate(output)), "Markdown")
}

func (b *Bot) handleSession(msg *tgbotapi.Message) {
	b.sessionsMu.RLock()
	session, ok := b.sessions[msg.From.ID]
	b.sessionsMu.RUnlock()
	if !ok || session.State != "shell" {
		return
	}

	cmd := strings.TrimSpace(msg.Text)
	if cmd == "" {
		return
	}

	cmd = normalizeCmd(cmd)

	dir := session.Dir
	b.audit(msg.From.ID, "shell", cmd, dir)
	output, err := localx.Exec(cmd, dir)

	parts := strings.SplitN(cmd, " ", 2)
	if len(parts) == 2 && parts[0] == "cd" {
		newDir := parts[1]
		if !strings.HasPrefix(newDir, "/") {
			newDir = dir + "/" + newDir
		}
		if fi, err := os.Stat(newDir); err == nil && fi.IsDir() {
			session.Dir = newDir
		}
	}

	if err != nil {
		b.reply(msg, fmt.Sprintf("```\n%s```", truncate(err.Error())), "Markdown")
		return
	}
	if output == "" {
		output = "(无输出)"
	}
	b.reply(msg, fmt.Sprintf("`%s:%s # %s`\n```\n%s```", hostname(), dir, cmd, truncate(output)), "Markdown")
}

func (b *Bot) sessionDir(userID int64) string {
	b.sessionsMu.RLock()
	defer b.sessionsMu.RUnlock()
	if s, ok := b.sessions[userID]; ok {
		return s.Dir
	}
	return ""
}

func (b *Bot) clearSession(userID int64) bool {
	b.sessionsMu.Lock()
	defer b.sessionsMu.Unlock()
	if _, ok := b.sessions[userID]; ok {
		delete(b.sessions, userID)
		return true
	}
	return false
}

func (b *Bot) reply(msg *tgbotapi.Message, text string, parseMode ...string) {
	m := tgbotapi.NewMessage(msg.Chat.ID, text)
	if len(parseMode) > 0 {
		m.ParseMode = parseMode[0]
	}
	m.ReplyToMessageID = msg.MessageID
	b.api.Send(m)
}

var auditMu sync.Mutex

func (b *Bot) audit(userID int64, mode, cmd, dir string) {
	auditMu.Lock()
	defer auditMu.Unlock()
	f, err := os.OpenFile("/tmp/tg-monbot/audit.log", os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	defer f.Close()
	ts := time.Now().Format("2006-01-02 15:04:05")
	if dir == "" {
		dir = "/"
	}
	fmt.Fprintf(f, "%s [%d] %s -> %s dir=%s cmd=%q\n", ts, userID, mode, hostname(), dir, cmd)
}

func normalizeCmd(cmd string) string {
	fields := strings.Fields(cmd)
	if len(fields) > 0 {
		switch fields[0] {
		case "top":
			return "top -b -n 1"
		}
	}
	return cmd
}

func truncate(s string) string {
	if len(s) > maxOutput {
		return s[:maxOutput] + "\n... (输出过长，已截断)"
	}
	return s
}

func dirToString(dir, cmd string) string {
	if dir == "" {
		return cmd
	}
	return fmt.Sprintf("%s # %s", dir, cmd)
}

var hostnameCache string

func hostname() string {
	if hostnameCache != "" {
		return hostnameCache
	}
	h, err := os.Hostname()
	if err != nil {
		return "router"
	}
	hostnameCache = h
	return h
}