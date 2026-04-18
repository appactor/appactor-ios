Pod::Spec.new do |s|
  s.name             = 'AppActorPlugin'
  s.version          = '0.0.7'
  s.summary          = 'AppActor native iOS plugin bridge for hybrid wrappers (Flutter, React Native).'
  s.homepage         = 'https://github.com/appactor/appactor-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'AppActor' => 'dev@appactor.com' }
  s.source           = { :git => 'https://github.com/appactor/appactor-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.swift_version = '5.9'

  s.source_files = 'Sources/AppActorPlugin/**/*.swift'
  s.dependency 'AppActor', '0.0.7'
end
