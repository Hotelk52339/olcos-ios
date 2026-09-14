// zz_olcrtcios_logbridge.go — olcrtc-ios BUILD SHIM, not upstream code.
//
// Upstream master removed mobile.SetLogWriter, but the entire core still logs
// through the stdlib `log` package (internal/logger wraps log.Print*), so a
// log.SetOutput bridge captures every core line. Living inside package `mobile`
// regenerates the exact pre-migration gomobile Swift names (MobileSetLogWriter,
// MobileLogWriterProtocol), so App/Core/TunnelEngine.swift's LogCapture is
// source-compatible with the previous framework.
//
// scripts/build-framework.sh copies this file into olcrtc-upstream/mobile/ right
// before `gomobile bind` and trap-deletes it after, so the submodule stays clean
// and nothing here is ever committed into upstream.
package mobile

import "log"

// LogWriter receives every core log line (one Write per log record).
type LogWriter interface {
	WriteLog(msg string)
}

type iosLogBridge struct{ w LogWriter }

func (b *iosLogBridge) Write(p []byte) (int, error) {
	b.w.WriteLog(string(p))
	return len(p), nil
}

// SetLogWriter routes the Go core's stdlib log output to w (nil = no-op).
// It also pins the stdlib log flags to time-only ("15:04:05 ") — the line shape
// the app's log pipeline (LogStore cleanup/redaction, WedgeDetector signatures)
// was built against; master's SetDebug no longer manages stdlib flags.
func SetLogWriter(w LogWriter) {
	if w == nil {
		return
	}
	log.SetFlags(log.Ltime)
	log.SetOutput(&iosLogBridge{w: w})
}
