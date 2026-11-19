module Shonin
  # In-process wake-up for chat long-polling. A waiter blocks on a channel for a
  # conversation; posting a message wakes every waiter on it. Per process only.
  module Hub
    @@waiters = {} of Int64 => Array(Channel(Nil))
    @@mutex = Mutex.new

    # Waits up to `timeout` for a message in the conversation. Returns true if woken.
    def self.wait(conversation_id : Int64, timeout : Time::Span) : Bool
      ch = Channel(Nil).new(1)
      @@mutex.synchronize { (@@waiters[conversation_id] ||= [] of Channel(Nil)) << ch }
      woken = false
      select
      when ch.receive
        woken = true
      when timeout(timeout)
      end
      @@mutex.synchronize do
        if list = @@waiters[conversation_id]?
          list.delete(ch)
          @@waiters.delete(conversation_id) if list.empty?
        end
      end
      woken
    end

    def self.notify(conversation_id : Int64) : Nil
      list = @@mutex.synchronize { @@waiters.delete(conversation_id) }
      list.try &.each { |ch| ch.send(nil) rescue nil }
    end
  end
end
