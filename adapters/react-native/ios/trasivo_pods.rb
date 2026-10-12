# Source pods preserve the same module boundaries as the Swift package. Call
# inside the application target before use_native_modules!/use_react_native!.
def use_trasivo!
  directory = File.expand_path(__dir__)
  %w[Trasivo TrasivoStorage TrasivoUI].each do |name|
    raise "Trasivo native inputs are missing: #{name}" unless File.directory?(File.join(directory, 'Core', name))
    pod name, :path => directory
  end
end
