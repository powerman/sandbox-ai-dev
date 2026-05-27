// Secure AND convenient sandbox for local development with AI Agents.
package main

import (
	"github.com/alecthomas/kong"
)

func main() {
	var cli struct{}
	ctx := kong.Parse(&cli,
		kong.Description("Secure AND convenient sandbox for local development with AI Agents"),
		kong.ShortUsageOnError(),
	)
	ctx.FatalIfErrorf(ctx.Run())
}
