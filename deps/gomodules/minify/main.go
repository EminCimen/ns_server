// @author Couchbase <info@couchbase.com>
// @copyright 2016-Present Couchbase, Inc.
//
// Use of this software is governed by the Business Source License included
// in the file licenses/BSL-Couchbase.txt.  As of the Change Date specified
// in that file, in accordance with the Business Source License, use of this
// software will be governed by the Apache License, Version 2.0, included in
// the file licenses/APL2.txt.
package main

import (
	"flag"
	"os"
	"log"
	"github.com/evanw/esbuild/pkg/api"
)

func printErrorAndExit(error string) {
	log.Printf(error)
	flag.Usage()
	os.Exit(1)
}

func main() {
	inDir := flag.String("in-dir", "", "path to js source dir (required)")
	outDir := flag.String("out-dir", "", "path to js output dir (required)")
	flag.Parse()
	log.SetFlags(0)

	if *inDir == "" {
		printErrorAndExit("Error: path to js source dir must be specified\n")
	}

	if *outDir == "" {
		printErrorAndExit("Error: path to js source dir must be specified\n")
	}

	result := api.Build(api.BuildOptions{
		MinifyWhitespace: true,
		// TODO: figure out why does't work
		// MinifyIdentifiers: true,
		MinifySyntax: true,

		NodePaths: []string{
			*inDir + "/ui/web_modules",
			*inDir + "/ui/libs",
			*inDir + "/ui/app",
		},
		EntryPoints: []string{
			*inDir + "/ui/app/main.js",
		},
		Pure: []string{"console.log"},
		Sourcemap: api.SourceMapLinked,
		KeepNames: true,
		Bundle: true,
		PreserveSymlinks: true,
		Splitting: true,
		Write: true,
		Format: api.FormatESModule,
		// LogLevel: api.LogLevelWarning,
		LogLevel: api.LogLevelInfo,
		Outdir: *outDir,
		Engines: []api.Engine{
			{api.EngineChrome, "93"},
			{api.EngineFirefox, "92"},
			{api.EngineSafari, "14"},
			{api.EngineEdge, "93"},
		},
	})

	if len(result.Errors) > 0 {
		os.Exit(1)
	}
}
