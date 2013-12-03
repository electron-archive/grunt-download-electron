# grunt-atom-shell

Download atom-shell.

## Installation

Install npm package, next to your project's `Gruntfile.js` file:

```
npm install grunt-atom-shell
```

Add this line to your project's `Gruntfile.js`:

```
grunt.loadNpmTasks('grunt-atom-shell');
```

## Options

* `version` - **Required** The version of atom-shell you want to download.
* `outputDir` - **Required** Where to put the downloaded atom-shell.
* `downloadDir` - Where to find and save cached downloaded atom-shell.
* `symbols` - Download debugging symbols instead of binaries, default to `false`.
* `rebuild` - Whether to rebuild native modules after atom-shell is downloaded.
* `apm` - The path to apm.
