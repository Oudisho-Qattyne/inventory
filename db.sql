-- ==========================================
-- 0. EXTENSIONS & REALTIME PUBLICATION
-- ==========================================

create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

begin;
    drop publication if exists supabase_realtime;
    create publication supabase_realtime;
commit;

-- ==========================================
-- 1. CORE TABLES
-- ==========================================

create table categories (
    id uuid primary key default uuid_generate_v4(),
    name text not null unique,
    description text,
    created_at timestamp with time zone default now(),
    updated_at timestamp with time zone default now()
);

create table warehouses (
    id uuid primary key default uuid_generate_v4(),
    name text not null,
    location text,
    created_at timestamp with time zone default now(),
    updated_at timestamp with time zone default now()
);

create table items (
    id uuid primary key default uuid_generate_v4(),
    name text not null,
    description text,
    category_id uuid references categories(id) on delete set null,
    created_at timestamp with time zone default now(),
    updated_at timestamp with time zone default now()
);

create table stock (
    id uuid primary key default uuid_generate_v4(),
    item_id uuid not null references items(id) on delete cascade,
    warehouse_id uuid not null references warehouses(id) on delete cascade,
    quantity integer not null default 0 check (quantity >= 0),
    updated_at timestamp with time zone default now(),
    unique(item_id, warehouse_id)
);

create table profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    username text unique not null,
    full_name text not null,
    role text not null check (role in ('admin', 'borrower')) default 'borrower',
    created_at timestamp with time zone default now(),
    updated_at timestamp with time zone default now()
);

create table borrow_requests (
    id uuid primary key default uuid_generate_v4(),
    user_id uuid not null references profiles(id) on delete cascade,
    status text not null check (status in ('pending', 'approved', 'partiallyApproved', 'rejected')) default 'pending',
    start_date date not null,
    end_date date not null,
    notes text,
    requested_at timestamp with time zone default now(),
    processed_at timestamp with time zone,
    processed_by uuid references profiles(id),
    created_at timestamp with time zone default now()
);

create table borrow_request_items (
    id uuid primary key default uuid_generate_v4(),
    request_id uuid not null references borrow_requests(id) on delete cascade,
    item_id uuid not null references items(id),
    warehouse_id uuid not null references warehouses(id),
    requested_quantity integer not null check (requested_quantity > 0),
    approved_quantity integer check (approved_quantity >= 0),
    unique(request_id, item_id, warehouse_id)
);

create table borrow_records (
    id uuid primary key default uuid_generate_v4(),
    request_id uuid references borrow_requests(id) on delete set null,
    user_id uuid not null references profiles(id),
    status text not null check (status in ('active', 'returned')) default 'active',
    start_date date not null,
    end_date date not null,
    borrowed_at timestamp with time zone default now(),
    returned_at timestamp with time zone,
    notes text,
    created_at timestamp with time zone default now()
);

create table borrow_record_items (
    id uuid primary key default uuid_generate_v4(),
    record_id uuid not null references borrow_records(id) on delete cascade,
    item_id uuid not null references items(id),
    warehouse_id uuid not null references warehouses(id),
    quantity integer not null check (quantity > 0),
    returned_quantity integer default 0 check (returned_quantity >= 0),
    unique(record_id, item_id, warehouse_id)
);

create table transactions (
    id uuid primary key default uuid_generate_v4(),
    type text not null check (type in ('transfer', 'adjustment')),
    from_warehouse_id uuid references warehouses(id),
    to_warehouse_id uuid references warehouses(id),
    warehouse_id uuid references warehouses(id),
    reason text,
    performed_by uuid not null references profiles(id),
    created_at timestamp with time zone default now()
);

create table transaction_items (
    id uuid primary key default uuid_generate_v4(),
    transaction_id uuid not null references transactions(id) on delete cascade,
    item_id uuid not null references items(id),
    quantity integer not null check (quantity > 0),
    unique(transaction_id, item_id)
);

create table audit_log (
    id uuid primary key default uuid_generate_v4(),
    table_name text not null,
    record_id uuid not null,
    action text not null,
    old_data jsonb,
    new_data jsonb,
    performed_by uuid references profiles(id),
    created_at timestamp with time zone default now()
);

-- ==========================================
-- 2. FUNCTIONS (all in one place)
-- ==========================================

-- Helper: update updated_at column
create or replace function update_updated_at_column()
returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

-- Helper: prevent negative stock
create or replace function check_stock_non_negative()
returns trigger as $$
begin
    if new.quantity < 0 then
        raise exception 'Stock quantity cannot be negative';
    end if;
    return new;
end;
$$ language plpgsql;

-- Helper: check if current user is admin
create or replace function is_admin()
returns boolean as $$
begin
    return exists (
        select 1 from profiles 
        where id = auth.uid() and role = 'admin'
    );
end;
$$ language plpgsql security definer;

-- Handle new user creation (from auth.users)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
as $$
begin
    insert into public.profiles (id, username, full_name, role)
    values (
        new.id,
        new.email,
        coalesce(new.raw_user_meta_data->>'full_name', new.email),
        coalesce(new.raw_user_meta_data->>'role', 'borrower')
    )
    on conflict (id) do nothing;
    return new;
end;
$$;

-- Process borrow request approval (deduct stock, create borrow records)
create or replace function process_borrow_request()
returns trigger as $$
declare
    req_item record;
    available_qty integer;
begin
    if (new.status in ('approved', 'partiallyApproved')) and 
       (old.status = 'pending') then
        
        for req_item in 
            select * from borrow_request_items where request_id = new.id
        loop
            declare
                qty_to_deduct integer := coalesce(req_item.approved_quantity, req_item.requested_quantity);
            begin
                if qty_to_deduct > 0 then
                    select quantity into available_qty 
                    from stock 
                    where item_id = req_item.item_id and warehouse_id = req_item.warehouse_id;
                    
                    if available_qty is null or available_qty < qty_to_deduct then
                        raise exception 'Insufficient stock for item % in warehouse %', 
                            req_item.item_id, req_item.warehouse_id;
                    end if;
                    
                    update stock 
                    set quantity = quantity - qty_to_deduct
                    where item_id = req_item.item_id and warehouse_id = req_item.warehouse_id;
                    
                    if not exists (select 1 from borrow_records where request_id = new.id) then
                        insert into borrow_records (request_id, user_id, status, start_date, end_date, notes)
                        values (new.id, new.user_id, 'active', new.start_date, new.end_date, new.notes);
                    end if;
                    
                    insert into borrow_record_items (record_id, item_id, warehouse_id, quantity)
                    select 
                        (select id from borrow_records where request_id = new.id),
                        req_item.item_id,
                        req_item.warehouse_id,
                        qty_to_deduct;
                end if;
            end;
        end loop;
        
        new.processed_at := now();
    end if;
    return new;
end;
$$ language plpgsql;

-- Process borrow return (restore stock)
create or replace function process_borrow_return()
returns trigger as $$
declare
    rec_item record;
begin
    if new.status = 'returned' and old.status = 'active' then
        for rec_item in 
            select * from borrow_record_items where record_id = new.id
        loop
            insert into stock (item_id, warehouse_id, quantity)
            values (rec_item.item_id, rec_item.warehouse_id, rec_item.quantity - rec_item.returned_quantity)
            on conflict (item_id, warehouse_id)
            do update set quantity = stock.quantity + (rec_item.quantity - rec_item.returned_quantity);
        end loop;
        new.returned_at := now();
    end if;
    return new;
end;
$$ language plpgsql;

-- Process stock transfers and adjustments
create or replace function process_stock_transfer()
returns trigger as $$
declare
    trans_item record;
    from_qty integer;
begin
    if new.type = 'transfer' then
        if new.from_warehouse_id = new.to_warehouse_id then
            raise exception 'Source and destination warehouses must be different';
        end if;
        for trans_item in 
            select * from transaction_items where transaction_id = new.id
        loop
            select quantity into from_qty
            from stock 
            where item_id = trans_item.item_id and warehouse_id = new.from_warehouse_id;
            if from_qty is null or from_qty < trans_item.quantity then
                raise exception 'Insufficient stock in source warehouse for item %', trans_item.item_id;
            end if;
            update stock 
            set quantity = quantity - trans_item.quantity
            where item_id = trans_item.item_id and warehouse_id = new.from_warehouse_id;
            insert into stock (item_id, warehouse_id, quantity)
            values (trans_item.item_id, new.to_warehouse_id, trans_item.quantity)
            on conflict (item_id, warehouse_id)
            do update set quantity = stock.quantity + trans_item.quantity;
        end loop;
    elsif new.type = 'adjustment' then
        for trans_item in 
            select * from transaction_items where transaction_id = new.id
        loop
            insert into stock (item_id, warehouse_id, quantity)
            values (trans_item.item_id, new.warehouse_id, trans_item.quantity)
            on conflict (item_id, warehouse_id)
            do update set quantity = trans_item.quantity;
        end loop;
    end if;
    return new;
end;
$$ language plpgsql;

-- Audit trigger function
create or replace function audit_trigger_func()
returns trigger as $$
begin
    if (tg_op = 'DELETE') then
        insert into audit_log (table_name, record_id, action, old_data, performed_by)
        values (tg_table_name, old.id, 'DELETE', row_to_json(old), auth.uid());
        return old;
    elsif (tg_op = 'UPDATE') then
        insert into audit_log (table_name, record_id, action, old_data, new_data, performed_by)
        values (tg_table_name, new.id, 'UPDATE', row_to_json(old), row_to_json(new), auth.uid());
        return new;
    elsif (tg_op = 'INSERT') then
        insert into audit_log (table_name, record_id, action, new_data, performed_by)
        values (tg_table_name, new.id, 'INSERT', row_to_json(new), auth.uid());
        return new;
    end if;
    return null;
end;
$$ language plpgsql;

-- Partial item returns (new function)
create or replace function process_partial_return(
    p_record_id uuid,
    p_items jsonb,
    p_notes text default null
)
returns jsonb
language plpgsql
security definer
as $$
declare
    v_item jsonb;
    v_record_item record;
    v_total_items integer;
    v_fully_returned_items integer;
    v_result jsonb;
begin
    if not exists (select 1 from borrow_records where id = p_record_id and status = 'active') then
        raise exception 'Borrow record not found or not active';
    end if;

    for v_item in select * from jsonb_array_elements(p_items)
    loop
        select * into v_record_item
        from borrow_record_items
        where record_id = p_record_id
        and item_id = (v_item->>'item_id')::uuid
        and warehouse_id = (v_item->>'warehouse_id')::uuid;
        
        if not found then
            raise exception 'Item % not found in borrow record', (v_item->>'item_id')::uuid;
        end if;
        
        if (v_item->>'return_quantity')::integer <= 0 then
            raise exception 'Return quantity must be positive for item %', (v_item->>'item_id')::uuid;
        end if;
        
        if (v_item->>'return_quantity')::integer > (v_record_item.quantity - v_record_item.returned_quantity) then
            raise exception 'Cannot return more than borrowed for item %', (v_item->>'item_id')::uuid;
        end if;
        
        update borrow_record_items
        set returned_quantity = returned_quantity + (v_item->>'return_quantity')::integer
        where id = v_record_item.id;
        
        insert into stock (item_id, warehouse_id, quantity)
        values ((v_item->>'item_id')::uuid, (v_item->>'warehouse_id')::uuid, (v_item->>'return_quantity')::integer)
        on conflict (item_id, warehouse_id)
        do update set quantity = stock.quantity + excluded.quantity, updated_at = now();
        
        insert into transactions (type, warehouse_id, reason, performed_by)
        values ('adjustment', (v_item->>'warehouse_id')::uuid,
                'Partial return for borrow record ' || p_record_id || 
                '. Item: ' || (v_item->>'item_id')::uuid || 
                '. Qty: ' || (v_item->>'return_quantity')::integer ||
                coalesce('. Notes: ' || p_notes, ''),
                auth.uid());
    end loop;
    
    select count(*) into v_total_items from borrow_record_items where record_id = p_record_id;
    select count(*) into v_fully_returned_items from borrow_record_items
    where record_id = p_record_id and returned_quantity = quantity;
    
    if v_total_items = v_fully_returned_items then
        update borrow_records
        set status = 'returned', returned_at = now(),
            notes = coalesce(notes || '. ', '') || 'Fully returned. ' || coalesce(p_notes, '')
        where id = p_record_id;
        v_result := jsonb_build_object(
            'status', 'fully_returned',
            'message', 'All items returned successfully. Borrow record closed.',
            'returned_items', v_total_items
        );
    else
        update borrow_records
        set notes = coalesce(notes || '. ', '') || 
                   'Partial return: ' || v_fully_returned_items::text || '/' || v_total_items::text || 
                   ' items fully returned. ' || coalesce(p_notes, '')
        where id = p_record_id;
        v_result := jsonb_build_object(
            'status', 'partially_returned',
            'message', 'Partial return processed. ' || 
                      (v_total_items - v_fully_returned_items)::text || ' item(s) still active.',
            'returned_items', v_fully_returned_items,
            'total_items', v_total_items
        );
    end if;
    return v_result;
end;
$$;

-- Direct borrow (admin quick borrow)
create or replace function create_direct_borrow(
    p_user_id uuid,
    p_end_date date,
    p_items jsonb,
    p_notes text,
    p_processed_by uuid
)
returns uuid
language plpgsql
security definer
as $$
declare
    v_record_id uuid;
    v_item jsonb;
begin
    insert into borrow_records (request_id, user_id, status, start_date, end_date, borrowed_at, notes)
    values (null, p_user_id, 'active', current_date, p_end_date, now(), p_notes)
    returning id into v_record_id;
    
    for v_item in select * from jsonb_array_elements(p_items)
    loop
        if (select quantity from stock 
            where item_id = (v_item->>'item_id')::uuid 
            and warehouse_id = (v_item->>'warehouse_id')::uuid) < (v_item->>'quantity')::integer then
            raise exception 'Insufficient stock for item %', (v_item->>'item_id')::uuid;
        end if;
        
        insert into borrow_record_items (record_id, item_id, warehouse_id, quantity)
        values (v_record_id, (v_item->>'item_id')::uuid, (v_item->>'warehouse_id')::uuid, (v_item->>'quantity')::integer);
        
        update stock 
        set quantity = quantity - (v_item->>'quantity')::integer, updated_at = now()
        where item_id = (v_item->>'item_id')::uuid 
        and warehouse_id = (v_item->>'warehouse_id')::uuid;
    end loop;
    return v_record_id;
end;
$$;

-- Manual stock adjustment
create or replace function adjust_stock(
    p_item_id uuid,
    p_warehouse_id uuid,
    p_quantity integer,
    p_reason text,
    p_performed_by uuid
)
returns void
language plpgsql
security definer
as $$
declare
    v_transaction_id uuid;
    v_current_quantity integer;
begin
    select quantity into v_current_quantity
    from stock
    where item_id = p_item_id and warehouse_id = p_warehouse_id;
    
    insert into transactions (type, warehouse_id, reason, performed_by)
    values ('adjustment', p_warehouse_id, p_reason, p_performed_by)
    returning id into v_transaction_id;
    
    insert into transaction_items (transaction_id, item_id, quantity)
    values (v_transaction_id, p_item_id, p_quantity);
    
    insert into stock (item_id, warehouse_id, quantity)
    values (p_item_id, p_warehouse_id, p_quantity)
    on conflict (item_id, warehouse_id)
    do update set quantity = excluded.quantity, updated_at = now();
    
    raise notice 'Stock adjusted: Item % in Warehouse % from % to %', 
        p_item_id, p_warehouse_id, v_current_quantity, p_quantity;
end;
$$;

-- Create borrow request (for borrowers)
create or replace function create_borrow_request(
    p_user_id uuid,
    p_start_date date,
    p_end_date date,
    p_notes text,
    p_items jsonb
)
returns uuid as $$
declare
    v_request_id uuid;
    item jsonb;
begin
    insert into borrow_requests (user_id, start_date, end_date, notes)
    values (p_user_id, p_start_date, p_end_date, p_notes)
    returning id into v_request_id;
    
    for item in select * from jsonb_array_elements(p_items)
    loop
        insert into borrow_request_items (request_id, item_id, warehouse_id, requested_quantity)
        values (v_request_id, (item->>'item_id')::uuid, (item->>'warehouse_id')::uuid, (item->>'quantity')::integer);
    end loop;
    return v_request_id;
end;
$$ language plpgsql security definer;

-- Approve borrow request (admin)
create or replace function approve_borrow_request(
    p_request_id uuid,
    p_status text,
    p_approved_items jsonb,
    p_notes text,
    p_processed_by uuid
)
returns boolean as $$
declare
    item jsonb;
begin
    for item in select * from jsonb_array_elements(p_approved_items)
    loop
        update borrow_request_items
        set approved_quantity = (item->>'approved_quantity')::integer
        where id = (item->>'request_item_id')::uuid and request_id = p_request_id;
    end loop;
    update borrow_requests
    set status = p_status, notes = coalesce(p_notes, notes), processed_by = p_processed_by
    where id = p_request_id;
    return true;
exception when others then
    return false;
end;
$$ language plpgsql security definer;

-- Create stock transfer (admin)
create or replace function create_stock_transfer(
    p_from_warehouse_id uuid,
    p_to_warehouse_id uuid,
    p_items jsonb,
    p_reason text,
    p_performed_by uuid
)
returns uuid as $$
declare
    v_transaction_id uuid;
    item jsonb;
begin
    insert into transactions (type, from_warehouse_id, to_warehouse_id, reason, performed_by)
    values ('transfer', p_from_warehouse_id, p_to_warehouse_id, p_reason, p_performed_by)
    returning id into v_transaction_id;
    
    for item in select * from jsonb_array_elements(p_items)
    loop
        insert into transaction_items (transaction_id, item_id, quantity)
        values (v_transaction_id, (item->>'item_id')::uuid, (item->>'quantity')::integer);
    end loop;
    return v_transaction_id;
end;
$$ language plpgsql security definer;

-- Get available stock for an item
create or replace function get_available_stock(p_item_id uuid)
returns table (warehouse_id uuid, warehouse_name text, quantity integer) as $$
begin
    return query
    select s.warehouse_id, w.name, s.quantity
    from stock s
    join warehouses w on s.warehouse_id = w.id
    where s.item_id = p_item_id and s.quantity > 0;
end;
$$ language plpgsql;

-- ==========================================
-- 3. TRIGGERS
-- ==========================================

-- updated_at triggers
create trigger update_categories_updated_at before update on categories
    for each row execute function update_updated_at_column();
create trigger update_warehouses_updated_at before update on warehouses
    for each row execute function update_updated_at_column();
create trigger update_items_updated_at before update on items
    for each row execute function update_updated_at_column();
create trigger update_stock_updated_at before update on stock
    for each row execute function update_updated_at_column();
create trigger update_profiles_updated_at before update on profiles
    for each row execute function update_updated_at_column();

-- Business logic triggers
create trigger trigger_process_borrow_request
    before update on borrow_requests
    for each row execute function process_borrow_request();

create trigger trigger_process_borrow_return
    before update on borrow_records
    for each row execute function process_borrow_return();

create trigger trigger_process_transaction
    after insert on transactions
    for each row execute function process_stock_transfer();

create trigger trigger_check_stock
    before update or insert on stock
    for each row execute function check_stock_non_negative();

-- Audit triggers
create trigger audit_stock after insert or update or delete on stock
    for each row execute function audit_trigger_func();
create trigger audit_borrow_requests after insert or update or delete on borrow_requests
    for each row execute function audit_trigger_func();
create trigger audit_borrow_records after insert or update or delete on borrow_records
    for each row execute function audit_trigger_func();
create trigger audit_transactions after insert or update or delete on transactions
    for each row execute function audit_trigger_func();

-- Auth trigger for new user
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- ==========================================
-- 4. ROW LEVEL SECURITY (RLS)
-- ==========================================

alter table categories enable row level security;
alter table warehouses enable row level security;
alter table items enable row level security;
alter table stock enable row level security;
alter table profiles enable row level security;
alter table borrow_requests enable row level security;
alter table borrow_request_items enable row level security;
alter table borrow_records enable row level security;
alter table borrow_record_items enable row level security;
alter table transactions enable row level security;
alter table transaction_items enable row level security;
alter table audit_log enable row level security;

-- Categories
create policy "Categories read access" on categories for select using (true);
create policy "Categories admin write" on categories for all using (is_admin()) with check (is_admin());

-- Warehouses
create policy "Warehouses read access" on warehouses for select using (true);
create policy "Warehouses admin write" on warehouses for all using (is_admin()) with check (is_admin());

-- Items
create policy "Items read access" on items for select using (true);
create policy "Items admin write" on items for all using (is_admin()) with check (is_admin());

-- Stock
create policy "Stock read access" on stock for select using (true);
create policy "Stock admin write" on stock for all using (is_admin()) with check (is_admin());

-- Profiles
create policy "Profiles read access" on profiles for select using (true);
create policy "Profiles update own" on profiles for update using (auth.uid() = id);
create policy "Profiles admin all" on profiles for all using (is_admin()) with check (is_admin());

-- Borrow Requests & Items
create policy "Requests user access" on borrow_requests for all using (user_id = auth.uid() or is_admin());
create policy "Request items access" on borrow_request_items for all using (
    exists (select 1 from borrow_requests where id = borrow_request_items.request_id and (user_id = auth.uid() or is_admin()))
);

-- Borrow Records & Items
create policy "Records user access" on borrow_records for all using (user_id = auth.uid() or is_admin());
create policy "Record items access" on borrow_record_items for all using (
    exists (select 1 from borrow_records where id = borrow_record_items.record_id and (user_id = auth.uid() or is_admin()))
);

-- Transactions & Items
create policy "Transactions read" on transactions for select using (true);
create policy "Transactions admin write" on transactions for all using (is_admin()) with check (is_admin());
create policy "Transaction items read" on transaction_items for select using (true);
create policy "Transaction items admin write" on transaction_items for all using (is_admin()) with check (is_admin());

-- Audit log
create policy "Audit log admin only" on audit_log for all using (is_admin());

-- ==========================================
-- 5. VIEWS
-- ==========================================

create view stock_view as
select 
    s.id,
    s.item_id,
    i.name as item_name,
    c.name as category_name,
    s.warehouse_id,
    w.name as warehouse_name,
    s.quantity,
    s.updated_at
from stock s
join items i on s.item_id = i.id
left join categories c on i.category_id = c.id
join warehouses w on s.warehouse_id = w.id;

create view pending_requests_view as
select 
    br.id,
    br.user_id,
    p.full_name as borrower_name,
    br.status,
    br.start_date,
    br.end_date,
    br.requested_at,
    count(bri.id) as item_count,
    sum(bri.requested_quantity) as total_quantity
from borrow_requests br
join profiles p on br.user_id = p.id
join borrow_request_items bri on br.id = bri.request_id
where br.status = 'pending'
group by br.id, p.full_name;

create view active_borrows_view as
select 
    br.id,
    br.user_id,
    p.full_name as borrower_name,
    br.start_date,
    br.end_date,
    br.borrowed_at,
    case 
        when br.end_date < current_date then 'overdue'
        else 'on_time'
    end as status,
    count(bri.id) as item_count
from borrow_records br
join profiles p on br.user_id = p.id
join borrow_record_items bri on br.id = bri.record_id
where br.status = 'active'
group by br.id, p.full_name;

-- ==========================================
-- 6. INDEXES
-- ==========================================

create index idx_stock_item on stock(item_id);
create index idx_stock_warehouse on stock(warehouse_id);
create index idx_borrow_requests_user on borrow_requests(user_id);
create index idx_borrow_requests_status on borrow_requests(status);
create index idx_borrow_records_user on borrow_records(user_id);
create index idx_borrow_records_status on borrow_records(status);
create index idx_audit_log_table on audit_log(table_name, created_at);
create index idx_items_category on items(category_id);

-- Add stock and borrow_requests to realtime publication
alter publication supabase_realtime add table stock;
alter publication supabase_realtime add table borrow_requests;

-- ==========================================
-- 7. GRANTS (optional, for Supabase)
-- ==========================================
grant execute on function process_partial_return(uuid, jsonb, text) to authenticated;