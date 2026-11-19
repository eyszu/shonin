module Shonin
  # Versioned schema. Each entry is applied once, in one transaction, and
  # recorded in `schema_migrations`. Add new entries at the end; never edit an
  # applied one.
  module Migrations
    record Migration, version : Int32, name : String, sql : String

    ALL = [
      Migration.new(1, "initial schema", <<-SQL),
        create table users (
          id                bigserial primary key,
          email             text        not null,
          password_hash     text        not null,
          role              text        not null default 'user' check (role in ('user', 'admin')),
          email_verified_at timestamptz,
          status            text        not null default 'active' check (status in ('active', 'banned')),
          ban_reason        text,
          banned_at         timestamptz,
          suspended_until   timestamptz,
          suspend_reason    text,
          created_at        timestamptz not null default now()
        );
        create unique index users_email_key on users (email);

        create table sessions (
          token_hash text        primary key,
          user_id    bigint      not null references users (id) on delete cascade,
          expires_at timestamptz not null,
          created_at timestamptz not null default now()
        );
        create index sessions_user_idx on sessions (user_id);

        create table email_tokens (
          token_hash text        primary key,
          user_id    bigint      not null references users (id) on delete cascade,
          expires_at timestamptz not null
        );
        create index email_tokens_user_idx on email_tokens (user_id);

        create table moderation_log (
          id         bigserial primary key,
          admin_id   bigint      not null references users (id),
          user_id    bigint      not null references users (id) on delete cascade,
          action     text        not null,
          reason     text,
          until_at   timestamptz,
          created_at timestamptz not null default now()
        );
        create index moderation_log_user_idx on moderation_log (user_id, id desc);

        create table categories (
          id         bigserial primary key,
          name       text        not null,
          created_at timestamptz not null default now()
        );
        create unique index categories_name_key on categories (lower(name));

        create table stores (
          id          bigserial primary key,
          owner_id    bigint      not null unique references users (id) on delete cascade,
          name        text        not null,
          description text        not null default '',
          logo        text,
          status      text        not null default 'open' check (status in ('open', 'closed')),
          created_at  timestamptz not null default now(),
          updated_at  timestamptz not null default now()
        );
        create unique index stores_name_key on stores (lower(name));

        create table products (
          id          bigserial primary key,
          store_id    bigint      not null references stores (id) on delete cascade,
          category_id bigint      references categories (id) on delete set null,
          name        text        not null,
          description text        not null default '',
          price_cents bigint      not null check (price_cents >= 0),
          stock       integer     not null default 0 check (stock >= 0),
          sold        integer     not null default 0 check (sold >= 0),
          status      text        not null default 'active' check (status in ('active', 'hidden')),
          created_at  timestamptz not null default now(),
          updated_at  timestamptz not null default now()
        );
        create index products_store_idx    on products (store_id, id desc);
        create index products_category_idx on products (category_id, id desc) where status = 'active';
        create index products_new_idx      on products (id desc) where status = 'active';
        create index products_price_idx    on products (price_cents, id) where status = 'active';
        create index products_popular_idx  on products (sold desc, id desc) where status = 'active';
        create index products_search_idx   on products
          using gin (to_tsvector('simple', name || ' ' || description));

        create table product_images (
          id         bigserial primary key,
          product_id bigint      not null references products (id) on delete cascade,
          filename   text        not null,
          position   integer     not null default 0,
          created_at timestamptz not null default now()
        );
        create index product_images_product_idx on product_images (product_id, position, id);

        create table cart_items (
          user_id    bigint  not null references users (id) on delete cascade,
          product_id bigint  not null references products (id) on delete cascade,
          qty        integer not null check (qty > 0),
          primary key (user_id, product_id)
        );

        create table orders (
          id            bigserial primary key,
          buyer_id      bigint      not null references users (id),
          store_id      bigint      not null references stores (id),
          status        text        not null default 'pending'
                        check (status in ('pending', 'confirmed', 'shipped', 'completed', 'cancelled')),
          total_cents   bigint      not null,
          ship_name     text        not null,
          ship_phone    text        not null,
          ship_address  text        not null,
          note          text        not null default '',
          cancel_reason text,
          created_at    timestamptz not null default now(),
          updated_at    timestamptz not null default now()
        );
        create index orders_buyer_idx on orders (buyer_id, id desc);
        create index orders_store_idx on orders (store_id, id desc);

        create table order_items (
          id          bigserial primary key,
          order_id    bigint  not null references orders (id) on delete cascade,
          product_id  bigint  references products (id) on delete set null,
          name        text    not null,
          price_cents bigint  not null,
          qty         integer not null check (qty > 0),
          image       text
        );
        create index order_items_order_idx on order_items (order_id);

        create table conversations (
          id               bigserial primary key,
          store_id         bigint      not null references stores (id) on delete cascade,
          customer_id      bigint      not null references users (id) on delete cascade,
          customer_read_id bigint      not null default 0,
          seller_read_id   bigint      not null default 0,
          last_message_id  bigint      not null default 0,
          created_at       timestamptz not null default now(),
          unique (store_id, customer_id)
        );
        create index conversations_customer_idx on conversations (customer_id, last_message_id desc);
        create index conversations_store_idx    on conversations (store_id, last_message_id desc);

        create table messages (
          id              bigserial primary key,
          conversation_id bigint      not null references conversations (id) on delete cascade,
          sender_id       bigint      not null references users (id),
          body            text        not null check (char_length(body) between 1 and 2000),
          created_at      timestamptz not null default now()
        );
        create index messages_conversation_idx on messages (conversation_id, id);
      SQL
    ]
  end
end
