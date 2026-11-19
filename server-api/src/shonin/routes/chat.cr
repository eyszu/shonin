module Shonin
  module Routes
    # Customer <-> seller chat. One conversation per (store, customer). Messages
    # are stored in PostgreSQL; clients poll with `after=<last id>&wait=<seconds>`
    # (long-poll), and the Hub wakes waiters the moment a message is posted.
    module ChatRoutes
      MAX_WAIT = 25

      record Party, conversation_id : Int64, store_id : Int64, customer_id : Int64, seller_id : Int64,
        customer_banned : Bool, seller_banned : Bool, me_is_customer : Bool

      private def self.mask(email : String) : String
        local, _, domain = email.partition('@')
        "#{local[0, 1]}***@#{domain}"
      end

      # Finds the conversation and checks the caller takes part in it.
      private def self.party!(id : Int64, user_id : Int64) : Party
        row = Shonin.db.query_one?(<<-SQL, id, user_id, as: {Int64, Int64, Int64, Int64, Bool, Bool})
          select c.id, c.store_id, c.customer_id, st.owner_id,
                 cu.status = 'banned', so.status = 'banned'
          from conversations c
          join stores st on st.id = c.store_id
          join users cu on cu.id = c.customer_id
          join users so on so.id = st.owner_id
          where c.id = $1 and (c.customer_id = $2 or st.owner_id = $2)
          SQL
        fail!(404, "not_found", "Conversation not found") unless row
        Party.new(row[0], row[1], row[2], row[3], row[4], row[5], row[2] == user_id)
      end

      private def self.insert_message(conversation_id : Int64, sender_id : Int64, as_customer : Bool, text : String) : {Int64, Time}
        result = Shonin.db.transaction do |tx|
          mid, at = tx.query_one(
            "insert into messages (conversation_id, sender_id, body) values ($1, $2, $3) returning id, created_at",
            conversation_id, sender_id, text, as: {Int64, Time})
          if as_customer
            tx.exec "update conversations set last_message_id = $2, customer_read_id = $2 where id = $1", conversation_id, mid
          else
            tx.exec "update conversations set last_message_id = $2, seller_read_id = $2 where id = $1", conversation_id, mid
          end
          {mid, at}
        end
        Hub.notify(conversation_id)
        result.not_nil!
      end

      private def self.write_message(b : JSON::Builder, row : {Int64, Int64, String, Time}, me : Int64) : Nil
        id, sender, body, at = row
        b.object do
          b.field "id", id
          b.field "sender_id", sender
          b.field "mine", sender == me
          b.field "body", body
          b.field "created_at", at
        end
      end

      private def self.fetch_messages(id : Int64, after : Int64?, before : Int64?, limit : Int32)
        if after
          Shonin.db.query_all(
            "select id, sender_id, body, created_at from messages where conversation_id = $1 and id > $2 order by id limit $3",
            id, after, limit, as: {Int64, Int64, String, Time})
        else
          Shonin.db.query_all(
            "select id, sender_id, body, created_at from messages where conversation_id = $1 and ($2::bigint is null or id < $2) order by id desc limit $3",
            id, before, limit + 1, as: {Int64, Int64, String, Time})
        end
      end

      private def self.open_to_customers!(store_id : Int64) : Int64
        owner = Shonin.db.query_one?(<<-SQL, store_id, as: Int64)
          select s.owner_id from stores s join users u on u.id = s.owner_id
          where s.id = $1 and s.status = 'open' and u.status = 'active'
          SQL
        owner || fail!(404, "not_found", "Store not found or not available")
      end

      def self.register(r : Spectre::Router) : Nil
        # POST /conversations {"store_id", "message"}: a customer writes to a store.
        r.post "/conversations", Guards::USER do |req, res|
          RateLimit.check!("chat:#{req.auth!.id}", 60, 1.minute)
          body = Body.parse(req)
          store_id = body.integer!("store_id", 1_i64, Int64::MAX)
          text = body.string!("message", 1, Config::MAX_MESSAGE_CHARS)
          me = req.auth!.id
          owner = open_to_customers!(store_id)
          fail!(422, "own_store", "You cannot message your own store") if owner == me
          cid = Shonin.db.query_one(
            "insert into conversations (store_id, customer_id) values ($1, $2) on conflict (store_id, customer_id) do update set store_id = excluded.store_id returning id",
            store_id, me, as: Int64)
          mid, _ = insert_message(cid, me, true, text)
          Api.json(res, 201) do |b|
            b.object do
              b.field "conversation_id", cid
              b.field "message_id", mid
            end
          end
        end

        # POST /stores/me/conversations {"customer_id", "message"}: a seller writes to
        # a customer who has ordered from the store.
        r.post "/stores/me/conversations", Guards::USER do |req, res|
          RateLimit.check!("chat:#{req.auth!.id}", 60, 1.minute)
          store = StoreRoutes.own_store!(req)
          body = Body.parse(req)
          customer_id = body.integer!("customer_id", 1_i64, Int64::MAX)
          text = body.string!("message", 1, Config::MAX_MESSAGE_CHARS)
          ok = Shonin.db.query_one?(<<-SQL, store[0], customer_id, as: Int32)
            select 1 from orders o join users u on u.id = o.buyer_id
            where o.store_id = $1 and o.buyer_id = $2 and u.status = 'active' limit 1
            SQL
          fail!(403, "no_relationship", "You can only message customers who have ordered from your store") unless ok
          cid = Shonin.db.query_one(
            "insert into conversations (store_id, customer_id) values ($1, $2) on conflict (store_id, customer_id) do update set store_id = excluded.store_id returning id",
            store[0], customer_id, as: Int64)
          mid, _ = insert_message(cid, req.auth!.id, false, text)
          Api.json(res, 201) do |b|
            b.object do
              b.field "conversation_id", cid
              b.field "message_id", mid
            end
          end
        end

        # GET /conversations?as=customer|seller&cursor=&limit=  (inbox, newest first)
        r.get "/conversations", Guards::SESSION do |req, res|
          me = req.auth!.id
          role = Api.string_query(req, "as", 10) || "customer"
          fail!(400, "invalid_as", "as must be customer or seller") unless {"customer", "seller"}.includes?(role)
          limit = Api.limit(req)
          cursor = Api.int_query(req, "cursor")

          if role == "customer"
            rows = Shonin.db.query_all(<<-SQL, me, cursor, limit + 1, as: {Int64, Int64, String, Int64, String?, Time?, Int64})
              select c.id, c.store_id, st.name, c.last_message_id,
                     (select body from messages where id = c.last_message_id),
                     (select created_at from messages where id = c.last_message_id),
                     (select count(*) from messages m where m.conversation_id = c.id and m.id > c.customer_read_id and m.sender_id <> c.customer_id)::bigint
              from conversations c join stores st on st.id = c.store_id
              where c.customer_id = $1 and ($2::bigint is null or c.last_message_id < $2)
              order by c.last_message_id desc limit $3
              SQL
            more = rows.size > limit
            rows = rows.first(limit) if more
            Api.page(res, more ? rows.last[3].to_s : nil) do |b|
              rows.each do |cid, store_id, name, _last, text, at, unread|
                b.object do
                  b.field "id", cid
                  b.field "store_id", store_id
                  b.field "with", name
                  b.field "last_message", text
                  b.field "last_message_at", at
                  b.field "unread", unread
                end
              end
            end
          else
            store = StoreRoutes.own_store!(req)
            rows = Shonin.db.query_all(<<-SQL, store[0], cursor, limit + 1, as: {Int64, Int64, String, Int64, String?, Time?, Int64})
              select c.id, c.customer_id, u.email, c.last_message_id,
                     (select body from messages where id = c.last_message_id),
                     (select created_at from messages where id = c.last_message_id),
                     (select count(*) from messages m where m.conversation_id = c.id and m.id > c.seller_read_id and m.sender_id = c.customer_id)::bigint
              from conversations c join users u on u.id = c.customer_id
              where c.store_id = $1 and ($2::bigint is null or c.last_message_id < $2)
              order by c.last_message_id desc limit $3
              SQL
            more = rows.size > limit
            rows = rows.first(limit) if more
            Api.page(res, more ? rows.last[3].to_s : nil) do |b|
              rows.each do |cid, customer_id, email, _last, text, at, unread|
                b.object do
                  b.field "id", cid
                  b.field "customer_id", customer_id
                  b.field "with", mask(email)
                  b.field "last_message", text
                  b.field "last_message_at", at
                  b.field "unread", unread
                end
              end
            end
          end
        end

        # GET /conversations/:id/messages?after=<id>&wait=<seconds>  or  ?before=<id>&limit=
        r.get "/conversations/:id/messages", Guards::SESSION do |req, res|
          me = req.auth!.id
          id = req.params.int("id")
          party = party!(id, me)
          after = Api.int_query(req, "after")
          before = Api.int_query(req, "before")
          limit = Api.limit(req, 50, 100)
          wait = (Api.int_query(req, "wait") || 0_i64).clamp(0_i64, MAX_WAIT.to_i64)

          rows = fetch_messages(id, after, before, limit)
          if after && rows.empty? && wait > 0
            Hub.wait(id, wait.seconds)
            rows = fetch_messages(id, after, before, limit)
          end

          next_cursor = nil
          unless after
            if rows.size > limit
              rows = rows.first(limit)
              next_cursor = rows.last[0].to_s
            end
            rows = rows.reverse
          end

          if newest = rows.max_of?(&.[0])
            if party.me_is_customer
              Shonin.db.exec "update conversations set customer_read_id = greatest(customer_read_id, $2) where id = $1", id, newest
            else
              Shonin.db.exec "update conversations set seller_read_id = greatest(seller_read_id, $2) where id = $1", id, newest
            end
          end
          Api.page(res, next_cursor) { |b| rows.each { |row| write_message(b, row, me) } }
        end

        # POST /conversations/:id/messages {"body"}
        r.post "/conversations/:id/messages", Guards::USER do |req, res|
          me = req.auth!.id
          RateLimit.check!("chat:#{me}", 60, 1.minute)
          party = party!(req.params.int("id"), me)
          other_banned = party.me_is_customer ? party.seller_banned : party.customer_banned
          fail!(403, "recipient_unavailable", "This user can no longer receive messages") if other_banned
          text = Body.parse(req).string!("body", 1, Config::MAX_MESSAGE_CHARS)
          mid, at = insert_message(party.conversation_id, me, party.me_is_customer, text)
          Api.json(res, 201) do |b|
            b.object do
              b.field "id", mid
              b.field "created_at", at
            end
          end
        end
      end
    end
  end
end
