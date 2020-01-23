package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"
	"syscall"

	"github.com/pkg/errors"
)

func main() {
	flag.Parse()
	args := flag.Args()
	if len(args) < 1 || len(args) > 2 {
		fmt.Fprintf(flag.CommandLine.Output(), "Usage: %s directory [command]", os.Args[0])
		flag.Usage()
	}
	if err := os.Chdir(args[0]); err != nil {
		fmt.Fprintf(flag.CommandLine.Output(), "chdir %s: %s", args[0], err)
		os.Exit(1)
	}

	var username string

	if os.Geteuid() == 0 {
		fileInfo, err := os.Stat(".")
		if err != nil {
			fmt.Fprintf(flag.CommandLine.Output(), "stat %s: %s", args[0], err)
			os.Exit(1)
		}
		if !fileInfo.IsDir() {
			fmt.Fprintf(flag.CommandLine.Output(), ". (%s): not a directory", args[0])
			os.Exit(1)
		}
		fileUid := fileInfo.Sys().(*syscall.Stat_t).Uid

		mapFD, err := os.Open("/etc/subuid")
		if err != nil {
			fmt.Fprintf(flag.CommandLine.Output(), "open /etc/subid: %s", err)
			os.Exit(1)
		}
		defer mapFD.Close()

		scanner := bufio.NewScanner(mapFD)
		for scanner.Scan() {
			line := scanner.Text()
			if strings.HasPrefix(line, "#") {
				continue
			}
			parts := strings.Split(line, ":")
			if len(parts) != 3 {
				continue
			}
			start, err := strconv.Atoi(line[1])
			if err != nil {
				continue
			}
			count, err := strconv.Atoi(line[2])
			if err != nil {
				continue
			}
			if fileUid >= start && fileUid <= start+count {
				username = line[0]
				break
			}
		}
		if username == "" {
			fmt.Fprintf(flag.CommandLine.Output(), "could not find user in /etc/subuid matching %d (owner of %s)", fileUid, args[0])
			os.Exit(1)
		}
	} else {
		u, err := user.LookupId(strconv.Itoa(os.Geteuid()))
		if err != nil {
			fmt.Fprintf(flag.CommandLine.Output(), "getpwnam(%d): %s", os.Geteuid(), err)
			os.Exit(1)
		}
		username = u.Username
	}

	uRange, err := getRange("/etc/subuid", username)
	if err != nil {
		fmt.Fprintf(flag.CommandLine.Output(), "lookup %s in /etc/subuid: %s", username, err)
		os.Exit(1)
	}
	gRange, err := getRange("/etc/subgid", username)
	if err != nil {
		fmt.Fprintf(flag.CommandLine.Output(), "lookup %s in /etc/subgid: %s", username, err)
		os.Exit(1)
	}

	cmd := exec.Command("newuidmap",
		strconv.Itoa(os.Getpid()),
		"0",
		strconv.Itoa(uRange.Start),
		strconv.Itoa(uRange.Count),
	)
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(flag.CommandLine.Output(), "%s failed: %s", cmd.String(), err)
		os.Exit(1)
	}

	cmd = exec.Command("newgidmap",
		strconv.Itoa(os.Getpid()),
		"0",
		strconv.Itoa(gRange.Start),
		strconv.Itoa(gRange.Count),
	)
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(flag.CommandLine.Output(), "%s failed: %s", cmd.String(), err)
		os.Exit(1)
	}

	if err := syscall.Chroot("."); err != nil {
		fmt.Fprintf(flag.CommandLine.Output(), "chroot %s: %s", args[0], err)
		os.Exit(1)
	}

	var cmd string
	if len(args) == 2 {
		cmd = args[2]
	} else {
		cmd = "/bin/sh"
	}
	err := syscall.Exec(cmd, []string{cmd}, os.Environ())
	fmt.Fprintf(flag.CommandLine.Output(), "exec %s failed: %s", cmd, err)
	os.Exit(1)

}

type Range struct {
	Start int
	Count int
}

func getRange(filename string, username string) (Range, error) {
	mapFD, err := os.Open(ilename)
	if err != nil {
		fmt.Fprintf(flag.CommandLine.Output(), "open %s: %s", filename, err)
		os.Exit(1)
	}
	defer mapFD.Close()

	scanner := bufio.NewScanner(mapFD)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, ":")
		if len(parts) != 3 {
			continue
		}
		if line[0] != username {
			continue
		}
		start, err := strconv.Atoi(line[1])
		if err != nil {
			return Range{}, errors.Wrap(err, "range start")
		}
		count, err := strconv.Atoi(line[2])
		if err != nil {
			return Range{}, errors.Wrap(err, "range length")
		}
		return Range{
			Start: start,
			Count: count,
		}, nil
	}
	return errors.Errorf("%s not found", username)
}
