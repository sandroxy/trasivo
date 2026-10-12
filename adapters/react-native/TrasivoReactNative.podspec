require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))
Pod::Spec.new do |s|
  s.name = 'TrasivoReactNative'
  s.version = package.fetch('version')
  s.summary = package.fetch('description')
  s.homepage = 'https://github.com/sandroxy/trasivo'
  s.license = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author = 'Sandroxy'
  s.source = { :git => 'https://github.com/sandroxy/trasivo.git', :tag => s.version.to_s }
  s.platform = :ios, '15.1'
  s.swift_version = '5.9'
  s.static_framework = true
  s.source_files = 'ios/Bridge/**/*.{swift,h,mm}'
  %w[Trasivo TrasivoStorage TrasivoUI].each { |name| s.dependency name, s.version.to_s }
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20' }
  install_modules_dependencies(s)
end
