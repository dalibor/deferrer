require 'spec_helper'
require 'timeout'
require 'logger'

describe Deferrer::Runner do
  let(:identifier) { 'some_identifier' }
  let(:redis) { Deferrer.redis }
  let(:list_key) { Deferrer::LIST_KEY }
  let(:logger) { Logger.new(STDOUT) }

  describe ".run" do
    it "processes jobs" do
      expect(Deferrer.worker).to receive(:call).with('TestWorker', 'test')

      Deferrer.defer_in(-1, identifier, 'TestWorker', 'test')
      Deferrer.run(single_run: true)
    end

    it "correctly sets arguments and converts symbols to strings for hashes" do
      expect(Deferrer.worker).to receive(:call).with('TestWorker', 1, 'arg1', { "a" => "b"})

      Deferrer.defer_in(-1, identifier, 'TestWorker', 1, 'arg1', { a: :b })
      Deferrer.run(single_run: true)
    end

    it "rescues standard errors" do
      allow(Deferrer).to receive(:next_item) { raise RuntimeError.new('error') }

      Deferrer.defer_in(-1, identifier, 'TestWorker', 'test')
      Deferrer.run(single_run: true)
    end

    it "rescues exceptions and logs and error messages" do
      expect(logger).to receive(:error).with("Error: Exception: error")
      allow(Deferrer).to receive(:next_item) { raise Exception.new('error') }

      Deferrer.logger = logger
      Deferrer.defer_in(-1, identifier, 'TestWorker', 'test')
      expect { Deferrer.run(single_run: true) }.to raise_error
    end
  end

  describe "logger" do
    before :each do
      Deferrer.logger = logger
    end

    it "logs info messages" do
      expect(logger).to receive(:info).with("Processing: deferred:#{identifier}")

      Deferrer.defer_in(-1, identifier, 'TestWorker', 'test')
      Deferrer.run(single_run: true)
    end

    it "logs error messages" do
      expect(logger).to receive(:error).with("Error: RuntimeError: error")
      allow(Deferrer).to receive(:next_item) { raise RuntimeError.new('error') }

      Deferrer.defer_in(-1, identifier, 'TestWorker', 'test')
      Deferrer.run(single_run: true)
    end

    it "logs error messages on exceptions" do
      expect(logger).to receive(:error).with("Error: Exception: error")
      allow(Deferrer).to receive(:next_item) { raise Exception.new('error') }

      Deferrer.defer_in(-1, identifier, 'TestWorker', 'test')
      expect { Deferrer.run(single_run: true) }.to raise_error
    end
  end

  describe ".defer_at" do
    it "deferrs at given time" do
      Deferrer.defer_at(Time.now, identifier, 'TestWorker', 'test')

      expect(redis.zrangebyscore(list_key, '-inf', Time.now.to_f, :limit => [0, 1]).first).not_to be_nil
      expect(redis.exists(item_key(identifier))).to be_truthy
    end
  end

  describe ".defer_in" do
    it "defers in given interval" do
      Deferrer.defer_in(1, identifier, 'TestWorker', 'test')

      expect(redis.zrangebyscore(list_key, '-inf', (Time.now + 1).to_f, :limit => [0, 1]).first).not_to be_nil
      expect(redis.exists(item_key(identifier))).to be_truthy
    end
  end

  describe ".next_item" do
    it "returns the next item" do
      Deferrer.defer_at(Time.now, identifier, 'TestWorker', 'test')

      item = Deferrer.next_item

      expect(item['class']).to eq('TestWorker')
      expect(item['args']).to eq(['test'])
    end

    it "returns last update of an item" do
      Deferrer.defer_at(Time.now - 3, identifier, 'TestWorker', 'test1')
      Deferrer.defer_at(Time.now - 2, identifier, 'TestWorker', 'test2')

      item = Deferrer.next_item

      expect(item['class']).to eq('TestWorker')
      expect(item['args']).to eq(['test2'])
    end

    it "keep the old score value" do
      Deferrer.defer_at(Time.now - 3, identifier, 'TestWorker', 'test1')
      Deferrer.defer_at(Time.now + 1, identifier, 'TestWorker', 'test2')

      expect(Deferrer.next_item).not_to be_nil
    end

    it "returns nil when no next item" do
      expect(Deferrer.next_item).to be_nil
    end

    it "removes values from redis" do
      Deferrer.defer_at(Time.now, identifier, 'TestWorker', 'test')

      item = Deferrer.next_item

      expect(redis.zrangebyscore(list_key, '-inf', Time.now.to_f, :limit => [0, 1]).first).to be_nil
      expect(redis.exists(item_key(identifier))).to be_falsey
      expect(Deferrer.next_item).to be_nil
    end

    it "doesn't block on empty lists" do
      Deferrer.defer_in(-1, identifier, 'TestWorker', 'test')
      redis.del(item_key(identifier))

      Timeout::timeout(2) { expect(Deferrer.next_item).to be_nil }
      expect(redis.zrangebyscore(list_key, '-inf', 'inf', :limit => [0, 1]).first).to be_nil
    end
  end
end
