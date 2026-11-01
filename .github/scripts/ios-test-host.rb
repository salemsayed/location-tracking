require 'xcodeproj'

project_path = File.join(ENV.fetch('RUNNER_TEMP'), 'ios-consumer/ios/App/App.xcodeproj')
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |target| target.name == 'App' }
tests = project.new_target(:unit_test_bundle, 'LocationTrackingPluginTests', :ios, '15.0')
tests.product_name = 'LocationTrackingPluginTests'
tests.product_reference.path = 'LocationTrackingPluginTests.xctest'
tests.add_dependency(app)
group = project.main_group.new_group('PluginTests')
Dir.glob(File.join(Dir.pwd, 'ios/Tests/LocationTrackingPluginTests/*.swift')).each do |path|
  tests.source_build_phase.add_file_reference(group.new_file(path))
end
app.package_product_dependencies.each do |product|
  tests.package_product_dependencies << product
  build = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build.product_ref = product
  tests.frameworks_build_phase.files << build
end
tests.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.brickssoft.locationtracking.tests',
    'SWIFT_VERSION' => '5.0',
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'PRODUCT_MODULE_NAME' => 'LocationTrackingPluginTests',
    'ENABLE_TESTING_SEARCH_PATHS' => 'YES',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/App.app/App',
    'BUNDLE_LOADER' => '$(TEST_HOST)',
    'CODE_SIGNING_ALLOWED' => 'NO'
  })
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.save_as(project_path, 'Stage1', true)
