package app

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"runtime/debug"
)

var (
	Version    string
	Modules    []string
	UserAgent  string
	ConfigPath string
	// WorkDir is the writable directory for all runtime files (config, logs,
	// cache). It is set from the -work-dir flag or the GO2RTC_WORK_DIR
	// environment variable.
	//
	// This exists for the Android embedded build: the app hands go2rtc a
	// private directory and every file is created inside it, so nothing
	// depends on the process current directory.
	WorkDir string
	Info    = make(map[string]any)
)

const usage = `Usage of go2rtc:

  -c, --config    Path to config file or config string as YAML or JSON, support multiple
  -d, --daemon    Run in background
  -v, --version   Print version and exit
      --work-dir  Writable directory for config/logs/cache (Android embedded)
`

func Init() {
	var config flagConfig
	var daemon bool
	var version bool
	var workDir string

	flag.Var(&config, "config", "")
	flag.Var(&config, "c", "")
	flag.BoolVar(&daemon, "daemon", false, "")
	flag.BoolVar(&daemon, "d", false, "")
	flag.BoolVar(&version, "version", false, "")
	flag.BoolVar(&version, "v", false, "")
	flag.StringVar(&workDir, "work-dir", "", "")

	flag.Usage = func() { fmt.Print(usage) }
	flag.Parse()

	// Environment variable fallback, so the Android app can pass the work
	// directory without touching the argument list.
	if workDir == "" {
		workDir = os.Getenv("GO2RTC_WORK_DIR")
	}
	if workDir != "" {
		if abs, err := filepath.Abs(workDir); err == nil {
			workDir = abs
		}
		if err := os.MkdirAll(workDir, 0700); err != nil {
			fmt.Println("Failed to create work dir:", err)
			os.Exit(1)
		}
		WorkDir = workDir
		Info["work_dir"] = workDir
	}

	revision, vcsTime := readRevisionTime()

	if version {
		fmt.Printf("go2rtc version %s (%s) %s/%s\n", Version, revision, runtime.GOOS, runtime.GOARCH)
		os.Exit(0)
	}

	if daemon && os.Getppid() != 1 {
		if runtime.GOOS == "windows" {
			fmt.Println("Daemon mode is not supported on Windows")
			os.Exit(1)
		}

		// Re-run the program in background and exit
		cmd := exec.Command(os.Args[0], os.Args[1:]...)
		if err := cmd.Start(); err != nil {
			fmt.Println("Failed to start daemon:", err)
			os.Exit(1)
		}
		fmt.Println("Running in daemon mode with PID:", cmd.Process.Pid)
		os.Exit(0)
	}

	UserAgent = "go2rtc/" + Version

	Info["version"] = Version
	Info["revision"] = revision

	initConfig(config)
	initLogger()

	platform := fmt.Sprintf("%s/%s", runtime.GOOS, runtime.GOARCH)
	Logger.Info().Str("version", Version).Str("platform", platform).Str("revision", revision).Msg("go2rtc")
	Logger.Debug().Str("version", runtime.Version()).Str("vcs.time", vcsTime).Msg("build")

	if ConfigPath != "" {
		Logger.Info().Str("path", ConfigPath).Msg("config")
	}

	var cfg struct {
		Mod struct {
			Modules []string `yaml:"modules"`
		} `yaml:"app"`
	}

	LoadConfig(&cfg)

	Modules = cfg.Mod.Modules
}

func readRevisionTime() (revision, vcsTime string) {
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, setting := range info.Settings {
			switch setting.Key {
			case "vcs.revision":
				if len(setting.Value) > 7 {
					revision = setting.Value[:7]
				} else {
					revision = setting.Value
				}
			case "vcs.time":
				vcsTime = setting.Value
			case "vcs.modified":
				if setting.Value == "true" {
					revision += ".dirty"
				}
			}
		}

		// Check version from -buildvcs info
		// Format for tagged version : v1.9.13
		// Format for modified code:   v1.9.14-0.20251215184105-753d6617ab58+dirty
		if info.Main.Version != "v"+Version {
			// Format: 1.9.13+dev.753d661[.dirty]
			// Compatible with "awesomeversion" and "packaging.version" from python.
			// Version will be larger than the previous release, but smaller than the next release.
			Version += "+dev." + revision
		}
	}
	return
}
