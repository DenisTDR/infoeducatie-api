RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner.clean_with(:deletion)
    Rails.application.load_seed
  end

  config.before do |example|
    DatabaseCleaner.strategy =
      example.metadata[:concurrent] ? :deletion : :transaction
    DatabaseCleaner.start
  end

  config.after do |example|
    DatabaseCleaner.clean
    Rails.application.load_seed if example.metadata[:concurrent]
  end
end
