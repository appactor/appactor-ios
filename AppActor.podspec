Pod::Spec.new do |s|
  s.name             = 'AppActor'
  s.version          = '0.0.7'
  s.summary          = 'AppActor iOS SDK — server-authoritative in-app purchase management.'
  s.homepage         = 'https://github.com/appactor/appactor-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'AppActor' => 'dev@appactor.com' }
  s.source           = { :git => 'https://github.com/appactor/appactor-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.swift_version = '5.9'

  s.source_files = 'Sources/AppActor/**/*.swift'
  s.resource_bundles = {
    'AppActor_Privacy' => ['Sources/AppActor/Resources/PrivacyInfo.xcprivacy']
  }
end
