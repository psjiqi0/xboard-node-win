package main

import (
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/cedar2025/xboard-node/internal/tgbot"
	"github.com/cedar2025/xboard-node/internal/tgconfig"
)

var (
	version = "dev"
)

func main() {
	cfgPath := flag.String("c", tgconfig.DefaultPath(), "配置文件路径")
	showVersion := flag.Bool("v", false, "显示版本")
	flag.Parse()

	if *showVersion {
		log.Printf("tg-monbot %s", version)
		return
	}

	log.SetFlags(log.LstdFlags | log.Lshortfile)
	log.Printf("tg-monbot %s 启动中...", version)

	cfg, err := tgconfig.Load(*cfgPath)
	if err != nil {
		log.Fatalf("加载配置失败: %v", err)
	}

	if cfg.BotToken == "" {
		log.Fatal("请在配置文件中设置 bot_token")
	}

	if !cfg.IsEnabled() {
		log.Printf("⚠️ 安全锁定：机器人未启用。请在配置文件中设置 chat_id 和 allowed_users，否则所有交互将被拒绝。")
	}

	bot, err := tgbot.NewBot(cfg)
	if err != nil {
		log.Fatalf("初始化 Bot 失败: %v", err)
	}

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-quit
		log.Println("正在关闭...")
		bot.Stop()
		os.Exit(0)
	}()

	bot.Start()
}
