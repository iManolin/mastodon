# frozen_string_literal: true

class Pubsubhubbub::DistributionWorker
  include Sidekiq::Worker

  sidekiq_options queue: 'push'

  def perform(stream_entry_ids)
    stream_entries = StreamEntry.where(id: stream_entry_ids).includes(:status).reject { |e| e.status&.direct_visibility? }

    return if stream_entries.empty?

    @account       = stream_entries.first.account
    @subscriptions = active_subscriptions.to_a

    distribute_public!(stream_entries.reject(&:hidden?))
    distribute_hidden!(stream_entries.select(&:hidden?)) if Rails.configuration.x.use_ostatus_privacy
  end

  private

  def distribute_public!(stream_entries)
    return if stream_entries.empty?

    @payload = OStatus::AtomSerializer.render(OStatus::AtomSerializer.new.feed(@account, stream_entries))

    Pubsubhubbub::DeliveryWorker.push_bulk(@subscriptions) do |subscription|
      [subscription.id, @payload]
    end
  end

  def distribute_hidden!(stream_entries)
    return if stream_entries.empty?

    @payload = OStatus::AtomSerializer.render(OStatus::AtomSerializer.new.feed(@account, stream_entries))
    @domains = @account.followers.domains

    Pubsubhubbub::DeliveryWorker.push_bulk(@subscriptions.select { |s| allowed_to_receive?(s.callback_url, s.domain) }) do |subscription|
      [subscription.id, @payload]
    end
  end

  def active_subscriptions
    Subscription.where(account: @account).active.select('id, callback_url, domain')
  end

  def allowed_to_receive?(callback_url, domain)
    (!domain.nil? && @domains.include?(domain)) || @domains.include?(Addressable::URI.parse(callback_url).host)
  end
end
