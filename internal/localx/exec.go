package localx

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"syscall"
	"time"
)

const (
	ExecTimeout  = 20 * time.Second
	DefaultShell = "/bin/sh"
)

func Exec(cmd, dir string) (string, error) {
	return ExecContext(context.Background(), cmd, dir, ExecTimeout)
}

func ExecContext(ctx context.Context, cmd, dir string, timeout time.Duration) (string, error) {
	var out bytes.Buffer

	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}

	c := exec.CommandContext(ctx, DefaultShell, "-c", cmd)
	if dir != "" {
		c.Dir = dir
	}
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	c.Stdout = &out
	c.Stderr = &out

	done := make(chan error, 1)
	go func() {
		done <- c.Run()
	}()

	var err error
	select {
	case err = <-done:
	case <-ctx.Done():
		if c.Process != nil {
			syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
		}
		<-done
		return out.String(), fmt.Errorf("命令执行超时（%s），已强制终止", timeout)
	}

	if ctx.Err() == context.DeadlineExceeded {
		return out.String(), fmt.Errorf("命令执行超时（%s），已强制终止\n%s", timeout, out.String())
	}
	if err != nil {
		if out.Len() > 0 {
			return out.String(), fmt.Errorf("%w\n%s", err, out.String())
		}
		return "", fmt.Errorf("命令执行失败: %w", err)
	}
	return out.String(), nil
}