fs       = require 'fs'
path     = require 'path'
os       = require 'os'
wrench   = require 'wrench'
GitHub   = require 'github-releases'
Progress = require 'progress'

module.exports = (grunt) ->
  spawn = (options, callback) ->
    childProcess = require 'child_process'
    stdout = []
    stderr = []
    error = null
    proc = childProcess.spawn options.cmd, options.args, options.opts
    proc.stdout.on 'data', (data) -> stdout.push data.toString()
    proc.stderr.on 'data', (data) -> stderr.push data.toString()
    proc.on 'exit', (code, signal) ->
      error = new Error(signal) if code != 0
      results = stderr: stderr.join(''), stdout: stdout.join(''), code: code
      grunt.log.error results.stderr if code != 0
      callback error, results, code

  getApmPath = ->
    apmPath = path.join 'apm', 'node_modules', 'atom-package-manager', 'bin', 'apm'
    apmPath = 'apm' unless grunt.file.isFile apmPath

    if process is 'win32' then "#{apmPath}.cmd" else apmPath

  getCurrentAtomShellVersion = (outputDir) ->
    versionPath = path.join outputDir, 'version'
    if grunt.file.isFile versionPath
      grunt.file.read(versionPath).trim()
    else
      null

  isAtomShellVersionCached = (downloadDir, version, platform) ->
    grunt.file.isFile path.join(downloadDir, version, platform, 'version')

  installAtomShell = (outputDir, downloadDir, version, platform) ->
    wrench.copyDirSyncRecursive path.join(downloadDir, version, platform), outputDir,
      forceDelete: true
      excludeHiddenUnix: false
      inflateSymlinks: false

  unzipAtomShell = (zipPath, callback) ->
    grunt.verbose.writeln 'Unzipping atom-shell.'
    directoryPath = path.dirname zipPath

    if process.platform is 'darwin'
      # The zip archive of darwin build contains symbol links, only the "unzip"
      # command can handle it correctly.
      spawn {cmd: 'unzip', args: [zipPath, '-d', directoryPath]}, (error) ->
        fs.unlinkSync zipPath
        callback error
    else
      DecompressZip = require('decompress-zip')
      unzipper = new DecompressZip(zipPath)
      unzipper.on 'error', callback
      unzipper.on 'extract', (log) ->
        fs.closeSync unzipper.fd
        fs.unlinkSync zipPath
        callback null
      unzipper.extract(path: directoryPath)

  saveAtomShellToCache = (inputStream, outputDir, downloadDir, version, platform, callback) ->
    wrench.mkdirSyncRecursive path.join downloadDir, version, platform
    cacheFile = path.join downloadDir, version, platform, 'atom-shell.zip'

    unless process.platform is 'win32'
      len = parseInt(inputStream.headers['content-length'], 10)
      progress = new Progress('downloading [:bar] :percent :etas', {complete: '=', incomplete: ' ', width: 20, total: len})

    outputStream = fs.createWriteStream(cacheFile)
    inputStream.pipe outputStream
    inputStream.on 'error', callback
    outputStream.on 'error', callback
    outputStream.on 'close', unzipAtomShell.bind this, cacheFile, callback
    inputStream.on 'data', (chunk) ->
      return if process.platform is 'win32'

      process.stdout.clearLine?()
      process.stdout.cursorTo?(0)
      progress.tick(chunk.length)

  rebuildNativeModules = (apm, previousVersion, currentVersion, callback) ->
    if currentVersion isnt previousVersion
      grunt.verbose.writeln "Rebuilding native modules for new atom-shell version #{currentVersion}."
      apm ?= getApmPath()
      spawn {cmd: apm, args: ['rebuild']}, callback
    else
      callback()

  grunt.registerTask 'download-atom-shell', 'Download atom-shell',  ->
    @requiresConfig "#{@name}.version", "#{@name}.outputDir"
    done = @async()

    {version, outputDir, downloadDir, symbols, rebuild, apm, platform, addPlatformToOutputPath} = grunt.config @name
    version = "v#{version}"
    downloadDir ?= path.join os.tmpdir(), 'downloaded-atom-shell'
    symbols ?= false
    rebuild ?= false
    platform ?= process.platform
    addPlatformToOutputPath ?= false

    if addPlatformToOutputPath
      downloadDir = path.join downloadDir, platform
      
    apm ?= getApmPath()

    # Do nothing if it's the expected version.
    currentAtomShellVersion = getCurrentAtomShellVersion outputDir
    return done() if currentAtomShellVersion is version

    # Try find the cached one.
    if isAtomShellVersionCached downloadDir, version, platform
      grunt.verbose.writeln("Installing cached atom-shell #{version}.")
      installAtomShell outputDir, downloadDir, version, platform
      rebuildNativeModules apm, currentAtomShellVersion, version, done
    else
      # Request the assets.
      github = new GitHub({repo: 'atom/atom-shell'})
      github.getReleases tag_name: version, (error, releases) ->
        unless releases?.length > 0
          grunt.log.error "Cannot find atom-shell #{version} for #{platform} from GitHub", error
          return done false

        # Which file to download
        filename =
          if symbols
            "atom-shell-#{version}-#{platform}-symbols.zip"
          else
            "atom-shell-#{version}-#{platform}.zip"

        # Find the asset of current platform.
        found = false
        for asset in releases[0].assets when asset.name is filename
          found = true
          github.downloadAsset asset, (error, inputStream) ->
            if error?
              grunt.log.error "Cannot download atom-shell #{version} for #{platform}", error
              return done false

            # Save file to cache.
            grunt.verbose.writeln "Downloading atom-shell #{version}."
            saveAtomShellToCache inputStream, outputDir, downloadDir, version, platform, (error) ->
              if error?
                grunt.log.error "Failed to download atom-shell #{version} for #{platform}", error
                return done false

              grunt.verbose.writeln "Installing atom-shell #{version}."
              installAtomShell outputDir, downloadDir, version, platform
              rebuildNativeModules apm, currentAtomShellVersion, version, done

        if not found
          grunt.log.error "Cannot find #{filename} in atom-shell #{version} release"
          done false
