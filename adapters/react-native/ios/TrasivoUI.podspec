require 'json'
package = JSON.parse(File.read(File.join(__dir__, '../package.json')))
Pod::Spec.new do |s|
  s.name = 'TrasivoUI'
  s.version = package.fetch('version')
  s.summary = 'Optional Trasivo transfer overlay and panel.'
  s.homepage = 'https://github.com/sandroxy/trasivo'
  s.license = { :type => 'Apache-2.0' }
  s.author = 'Sandroxy'
  s.source = { :git => 'https://github.com/sandroxy/trasivo.git', :tag => s.version.to_s }
  s.platform = :ios, '13.0'
  s.swift_version = '5.9'
  s.static_framework = true
  s.source_files = 'Core/TrasivoUI/**/*.swift'
  s.frameworks = 'UIKit'
  s.dependency 'Trasivo', s.version.to_s
end
