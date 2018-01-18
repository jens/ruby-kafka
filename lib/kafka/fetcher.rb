require "kafka/fetch_operation"

module Kafka
  class Fetcher
    attr_reader :queue

    def initialize(cluster:, logger:, instrumenter:)
      @cluster = cluster
      @logger = logger
      @instrumenter = instrumenter

      @queue = Queue.new
      @current_offsets = Hash.new { |h, k| h[k] = {} }
      @thread = nil
    end

    def start(partitions:, min_bytes:, max_bytes:, max_wait_time:)
      @partitions = partitions
      @min_bytes = min_bytes
      @max_bytes = max_bytes
      @max_wait_time = max_wait_time

      raise "already started" if @running

      @running = true

      @thread = Thread.new do
        step while @running
      end

      @thread.abort_on_exception = true
    end

    def stop
      @running = false
    end

    private

    def step
      batches = fetch_batches

      batches.each do |batch|
        unless batch.empty?
          @instrumenter.instrument("fetch_batch.consumer", {
            topic: batch.topic,
            partition: batch.partition,
            offset_lag: batch.offset_lag,
            highwater_mark_offset: batch.highwater_mark_offset,
            message_count: batch.messages.count,
          })
        end

        @logger.info "=== Enqueueing batch"
        @queue << batch

        @current_offsets[batch.topic][batch.partition] = batch.last_offset
      end
    end

    def fetch_batches
      @logger.info "=== FETCHING BATCHES ==="

      operation = FetchOperation.new(
        cluster: @cluster,
        logger: @logger,
        min_bytes: @min_bytes,
        max_bytes: @max_bytes,
        max_wait_time: @max_wait_time,
      )

      @partitions.each do |topic, partitions|
        partitions.each do |partition|
          # When automatic marking is off, the first poll needs to be based on the last committed
          # offset from Kafka, that's why we fallback in case of nil (it may not be 0)
          if @current_offsets[topic].key?(partition)
            offset = @current_offsets[topic][partition] + 1
          else
            offset = 0
          end

          @logger.debug "Fetching batch from #{topic}/#{partition} starting at offset #{offset}"
          operation.fetch_from_partition(topic, partition, offset: offset)
        end
      end

      operation.execute
    rescue NoPartitionsToFetchFrom
      backoff = @max_wait_time > 0 ? @max_wait_time : 1

      @logger.info "There are no partitions to fetch from, sleeping for #{backoff}s"
      sleep backoff

      retry
    end
  end
end
