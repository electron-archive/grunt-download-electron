fs       = require 'fs'
path     = require 'path'
os       = require 'os'
wrench   = require 'wrench'
GitHub   = require 'github-releases'
Progress = require 'progress'

TaskName = "download-electron"

module.exports = (grunt) ->
  spawn = (options, callback) ->
    childProcess = require 'child_process'
    stdout = []
    stderr = []
    error = null
    proc = childProcess.spawn options.cmd, options.args, options.opts
    proc.stdout.on 'data', (data) -> stdout.push data.toString()
    proc.stderr.on 'data', (data) -> stderr.push data.toString()
    proc.on 'error', (processError) -> error ?= processError
    proc.on 'exit', (code, signal) ->
      error ?= new Error(signal) if code != 0
      results = stderr: stderr.join(''), stdout: stdout.join(''), code: code
      grunt.log.error results.stderr if code != 0
      callback error, results, code

  getArch = ->
    switch process.platform
      when 'win32' then 'ia32'
      when 'darwin' then 'x64'
      else process.arch

  getApmPath = ->
    apmPath = path.join 'apm', 'node_modules', 'atom-package-manager', 'bin', 'apm'
    apmPath = 'apm' unless grunt.file.isFile apmPath

    if process.platform is 'win32' then "#{apmPath}.cmd" else apmPath

  getAtomShellVersion = (directory) ->
    versionPath = path.join directory, 'version'
    if grunt.file.isFile versionPath
      grunt.file.read(versionPath).trim()
    else
      null

  copyDirectory = (fromPath, toPath) ->
    wrench.copyDirSyncRecursive fromPath, toPath,
      forceDelete: true
      excludeHiddenUnix: false
      inflateSymlinks: false

  unzipFile = (zipPath, callback) ->
    grunt.verbose.writeln "Unzipping #{path.basename(zipPath)}."
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
      unzipper.on 'extract', ->
        fs.closeSync unzipper.fd
        fs.unlinkSync zipPath

        # Make sure atom/electron is executable on Linux
        if process.platform is 'linux'
          electronAppPath = path.join(directoryPath, 'electron')
          fs.chmodSync(electronAppPath, '755') if fs.existsSync(electronAppPath)

          atomAppPath = path.join(directoryPath, 'atom')
          fs.chmodSync(atomAppPath, '755') if fs.existsSync(atomAppPath)

        callback null
      unzipper.extract(path: directoryPath)

  downloadAndUnzip = (inputStream, zipFilePath, callback) ->
    wrench.mkdirSyncRecursive(path.dirname(zipFilePath))

    unless process.platform is 'win32'
      len = parseInt(inputStream.headers['content-length'], 10)
      progress = new Progress('downloading [:bar] :percent :etas', {complete: '=', incomplete: ' ', width: 20, total: len})

    outputStream = fs.createWriteStream(zipFilePath)
    inputStream.pipe outputStream
    inputStream.on 'error', callback
    outputStream.on 'error', callback
    outputStream.on 'close', unzipFile.bind this, zipFilePath, callback
    inputStream.on 'data', (chunk) ->
      return if process.platform is 'win32'

      process.stdout.clearLine?()
      process.stdout.cursorTo?(0)
      progress.tick(chunk.length)

  rebuildNativeModules = (apm, previousVersion, currentVersion, needToRebuild, callback, appDir) ->
    if currentVersion isnt previousVersion and needToRebuild
      grunt.verbose.writeln "Rebuilding native modules for new electron version #{currentVersion}."
      apm ?= getApmPath()

      # When we spawn apm, we still want to use the global environment variables
      options = env: {}
      options.env[key] = value for key, value of process.env
      options.env.ATOM_NODE_VERSION = currentVersion.substr(1)

      # If the appDir has been set, then that is where we want to perform the rebuild.
      # it defaults to the current directory
      options.cwd = appDir if appDir
      spawn {cmd: apm, args: ['rebuild'], opts: options}, callback
    else
      callback()

  grunt.registerTask TaskName, 'Download electron',  ->
    @requiresConfig "#{TaskName}.version", "#{TaskName}.outputDir"
    {version, outputDir, downloadDir, symbols, rebuild, apm, token, appDir} = grunt.config TaskName
    downloadDir ?= path.join os.tmpdir(), 'downloaded-electron'
    symbols ?= false
    rebuild ?= true
    apm ?= getApmPath()
    version = "v#{version}"
    versionDownloadDir = path.join(downloadDir, version)
    appDir ?= process.cwd()

    done = @async()

    # Do nothing if the desired version of electron is already installed.
    currentAtomShellVersion = getAtomShellVersion(outputDir)
    return done() if currentAtomShellVersion is version

    # Install a cached download of electron if one is available.
    if getAtomShellVersion(versionDownloadDir)?
      grunt.verbose.writeln("Installing cached electron #{version}.")
      copyDirectory(versionDownloadDir, outputDir)
      rebuildNativeModules apm, currentAtomShellVersion, version, rebuild, done, appDir
      return

    # Request the assets.
    github = new GitHub({repo: 'electron/electron', token})
    github.getReleases tag_name: version, (error, releases) ->
      unless releases?.length > 0
        grunt.log.error "Cannot find electron #{version} from GitHub", error
        return done false


      atomShellAssets = releases[0].assets.filter ({name}) -> name.indexOf('atom-shell-') is 0
      if atomShellAssets.length > 0
        projectName = 'atom-shell'
      else
        projectName = 'electron'

      # Which file to download
      filename =
        if symbols
          "#{projectName}-#{version}-#{process.platform}-#{getArch()}-symbols.zip"
        else
          "#{projectName}-#{version}-#{process.platform}-#{getArch()}.zip"

      # Find the asset of current platform.
      for asset in releases[0].assets when asset.name is filename
        github.downloadAsset asset, (error, inputStream) ->
          if error?
            grunt.log.error "Cannot download electron #{version}", error
            return done false

          # Save file to cache.
          grunt.verbose.writeln "Downloading electron #{version}."
          downloadAndUnzip inputStream, path.join(versionDownloadDir, "#{projectName}.zip"), (error) ->
            if error?
              grunt.log.error "Failed to download electron #{version}", error
              return done false

            grunt.verbose.writeln "Installing electron #{version}."
            copyDirectory(versionDownloadDir, outputDir)
            rebuildNativeModules apm, currentAtomShellVersion, version, rebuild, done, appDir
        return

      grunt.log.error "Cannot find #{filename} in electron #{version} release"
      done false

  grunt.registerTask "#{TaskName}-chromedriver", 'Download the chromedriver binary distributed with electron',  ->
    @requiresConfig "#{TaskName}.version", "#{TaskName}.outputDir"
    {version, outputDir, downloadDir, token} = grunt.config(TaskName)
    version = "v#{version}"
    downloadDir ?= path.join os.tmpdir(), 'downloaded-electron'
    chromedriverPath = path.join(outputDir, "chromedriver")

    done = @async()

    # Chromedriver is only distributed with the first patch release for any
    # given major and minor version of electron.
    versionWithChromedriver = version.split(".").slice(0, 2).join(".") + ".0"
    downloadPath = path.join(downloadDir, "#{versionWithChromedriver}-chromedriver")

    # Do nothing if the desired version of electron is already installed with
    # a chromedriver executable.
    currentAtomShellVersion = getAtomShellVersion(outputDir)
    return done() if currentAtomShellVersion is version and grunt.file.isDir(chromedriverPath)

    # Use a cached download of chromedriver if one exists.
    if grunt.file.isDir(downloadPath)
      grunt.verbose.writeln("Installing cached chromedriver #{versionWithChromedriver}.")
      copyDirectory(downloadPath, chromedriverPath)
      return done()

    # Request the assets.
    github = new GitHub({repo: 'atom/electron', token})
    github.getReleases tag_name: versionWithChromedriver, (error, releases) ->
      unless releases?.length > 0
        grunt.log.error "Cannot find electron #{versionWithChromedriver} from GitHub", error
        return done false

      # Find the asset for the current platform and architecture.
      assetNameRegex = ///chromedriver-.*-#{process.platform}-#{getArch()}///
      for asset in releases[0].assets when assetNameRegex.test(asset.name)
        github.downloadAsset asset, (error, inputStream) ->
          if error?
            grunt.log.error "Cannot download chromedriver for electron #{versionWithChromedriver}", error
            return done false

          # Save file to cache.
          grunt.verbose.writeln "Downloading chromedriver for electron #{versionWithChromedriver}."
          downloadAndUnzip inputStream, path.join(downloadPath, "chromedriver.zip"), (error) ->
            if error?
              grunt.log.error "Failed to download chromedriver for electron #{versionWithChromedriver}", error
              return done false

            grunt.verbose.writeln "Installing chromedriver for electron #{versionWithChromedriver}."
            copyDirectory(downloadPath, chromedriverPath)

            # Make sure chromedriver is executable on Linux
            if process.platform is 'linux'
              chromedriverExecutablePath = path.join(chromedriverPath, 'chromedriver')
              fs.chmodSync(chromedriverExecutablePath, '755') if fs.existsSync(chromedriverExecutablePath)

            done()
        return

      grunt.log.error "Cannot find chromedriver in electron #{versionWithChromedriver} release"
      done false
