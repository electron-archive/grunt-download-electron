fs     = require 'fs'
path   = require 'path'
os     = require 'os'
wrench = require 'wrench'
GitHub = require 'github-releases'

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

  getTokenFromKeychain = (callback) ->
    accessToken = process.env['ATOM_ACCESS_TOKEN']
    if accessToken
      callback(null, accessToken)
      return

    spawn {cmd: 'security', args: ['-q', 'find-generic-password', '-ws', 'GitHub API Token']}, (error, result, code) ->
      accessToken = result.stdout unless error?
      callback(error, accessToken)

  getCurrentAtomShellVersion = (outputDir) ->
    versionPath = path.join outputDir, 'version'
    if grunt.file.isFile versionPath
      grunt.file.read(versionPath).trim()
    else
      null

  isAtomShellVersionCached = (downloadDir, version) ->
    grunt.file.isFile path.join(downloadDir, version, 'version')

  installAtomShell = (outputDir, downloadDir, version) ->
    wrench.copyDirSyncRecursive path.join(downloadDir, version), outputDir,
      forceDelete: true
      excludeHiddenUnix: false
      inflateSymlinks: false

  unzipAtomShell = (zipPath, callback) ->
    grunt.verbose.writeln 'Unzipping atom-shell'
    directoryPath = path.dirname zipPath

    if process.platform is 'darwin'
      # The zip archive of darwin build contains symbol links, only the "unzip"
      # command can handle it correctly.
      spawn {cmd: 'unzip', args: [zipPath, '-d', directoryPath]}, (error) ->
        fs.unlinkSync zipPath
        callback error
    else
      fileStream = fs.createReadStream zipPath
      fileStream.on 'error', callback
      zipStream = fileStream.pipe unzip.Extract(path: directoryPath)
      zipStream.on 'error', callback
      zipStream.on 'close', ->
        fs.unlinkSync zipPath
        callback null

  saveAtomShellToCache = (inputStream, outputDir, downloadDir, version, callback) ->
    wrench.mkdirSyncRecursive path.join downloadDir, version
    cacheFile = path.join downloadDir, version, 'atom-shell.zip'

    inputStream.pipe fs.createWriteStream(cacheFile)
    inputStream.on 'error', callback
    inputStream.on 'end', ->
      unzipAtomShell cacheFile, (error) ->
        return callback error if error?

  grunt.registerTask 'update-atom-shell', 'Update atom-shell',  ->
    @requiresConfig "#{@name}.version", "#{@name}.outputDir"
    done = @async()

    {version, outputDir, downloadDir} = grunt.config @name
    version = "v#{version}"
    downloadDir ?= path.join os.tmpdir(), 'downloaded-atom-shell'

    # Do nothing if it's the expected version.
    return done() if getCurrentAtomShellVersion(outputDir) is version

    # Try find the cached one.
    if isAtomShellVersionCached downloadDir, version
      grunt.verbose.writeln("Installing cached atom-shell #{version}")
      installAtomShell outputDir, downloadDir, version
      return done()

    # Get the token.
    getTokenFromKeychain (error, token) ->
      if error?
        grunt.log.error 'Cannot get GitHub token for accessing atom/atom-shell'
        return done false

      # Request the assets.
      github = new GitHub({repo: 'atom/atom-shell', token})
      filename = "atom-shell-#{version}-#{process.platform}.zip"
      github.getReleases tag_name: version, (error, releases) ->
        if releases.length is 0
          grunt.log.error "Cannot find atom-shell #{version} from GitHub"
          return done false

        # Find the asset of current platform.
        found = false
        for asset in releases[0].assets when asset.name is filename
          found = true
          github.downloadAsset asset, (error, inputStream) ->
            if error?
              grunt.log.error "Cannot download atom-shell #{version}", error
              return done false

            # Save file to cache.
            grunt.verbose.writeln "Downloading atom-shell #{version}"
            saveAtomShellToCache inputStream, outputDir, downloadDir, version, (error) ->
              if error?
                grunt.log.error "Failed to download atom-shell #{version}", error
                return done false

              grunt.verbose.writeln "Installing atom-shell #{version}"
              installAtomShell outputDir, downloadDir, version
              return done()

        if not found
          grunt.log.error "Cannot find #{filename} in atom-shell #{version} release"
          done false
