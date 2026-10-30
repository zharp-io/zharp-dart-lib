Pod::Spec.new do |s|
  s.name             = 'zharp_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Zharp Application Monitoring for Flutter.'
  s.description      = 'Device context (model, OS, install ID) for the zharp_flutter Dart package.'
  s.homepage         = 'https://zharp.io'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Zharp' => 'support@zharp.io' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version    = '5.0'
  s.resource_bundles = { 'zharp_flutter_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
end
