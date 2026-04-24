use_frameworks!

MAC_TARGET_VERSION = '26.0'
IOS_TARGET_VERSION = '14'

def mac_pods
    pod 'MASShortcut', :git => 'https://github.com/glushchenko/MASShortcut.git', :branch => 'master'
end

def ios_pods
    pod 'SSZipArchive', :git => 'https://github.com/glushchenko/ZipArchive.git', :branch => 'master'
    pod 'DropDown', '2.3.13'
    pod 'SwipeCellKit', :git => 'https://github.com/glushchenko/SwipeCellKit.git', :branch => 'develop'
    pod 'CropViewController'
end

def common_pods
    pod 'libcmark_gfm', :git => 'https://github.com/glushchenko/libcmark_gfm', :branch => 'master' 
    pod 'RNCryptor', '~> 5.1.0'
    pod 'SSZipArchive', :git => 'https://github.com/glushchenko/ZipArchive.git', :branch => 'master'
    pod 'Punycode'
end

def framework_pods
    pod 'SwiftLint', '~> 0.30.0'
end

target 'FSNotes' do
    platform :osx, MAC_TARGET_VERSION

    mac_pods
    common_pods

    target 'FSNotesTests' do
        inherit! :search_paths
    end
end

target 'FSNotes (iCloud)' do
    platform :osx, MAC_TARGET_VERSION

    mac_pods
    common_pods
end

target 'FSNotes iOS' do
    platform :ios, IOS_TARGET_VERSION

    common_pods
    ios_pods
end

target 'FSNotes iOS Share Extension' do
    platform :ios, IOS_TARGET_VERSION

    pod 'RNCryptor', '~> 5.1.0'
    pod 'SSZipArchive', :git => 'https://github.com/glushchenko/ZipArchive.git', :branch => 'master'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    if target.name == 'cmark-gfm-swift-macOS'
      source_files = target.source_build_phase.files
      dummy = source_files.find do |file|
        file.file_ref.name == 'scanners.re'
      end
      source_files.delete dummy

      dummyM = source_files.find do |file|
        file.file_ref.name == 'module.modulemap'
      end
      source_files.delete dummyM
      puts "Deleting source file #{dummy.inspect} from target #{target.inspect}."
    end

    if target.name == 'libcmark_gfm-macOS' ||
      target.name == 'MASShortcut' ||
      target.name == 'SSZipArchive-macOS' ||
      target.name == 'RNCryptor-macOS'

      target.build_configurations.each do |config|
        config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '26.0'
      end
    end

    if target.name == 'SSZipArchive-iOS' ||
      target.name == 'RNCryptor-iOS' ||
      target.name == 'DropDown' ||
      target.name == 'DKCamera' ||
      target.name == 'CropViewController'

      target.build_configurations.each do |config|
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
      end
    end

    # Silence -Wstrict-prototypes on the libcmark_gfm C sources. The flag
    # emits hundreds of warnings per build from third-party markdown-parsing
    # C code, flooding the Xcode issue navigator and burying real warnings
    # in our own Swift code. Scope is limited to the Pod target; our source
    # compiles with the full warning set unchanged.
    if target.name == 'libcmark_gfm-macOS' || target.name == 'libcmark_gfm-iOS'
      target.build_configurations.each do |config|
        if config.build_settings['WARNING_CFLAGS'].is_a?(Array)
          config.build_settings['WARNING_CFLAGS'].delete('-Wstrict-prototypes')
        end
        config.build_settings['GCC_WARN_STRICT_PROTOTYPES'] = 'NO'
        config.build_settings['OTHER_CFLAGS'] ||= ['$(inherited)']
        unless config.build_settings['OTHER_CFLAGS'].is_a?(Array)
          config.build_settings['OTHER_CFLAGS'] = [config.build_settings['OTHER_CFLAGS']]
        end
        config.build_settings['OTHER_CFLAGS'] << '-Wno-strict-prototypes'
      end
    end
  end
end
