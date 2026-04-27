-- Run this in Supabase SQL Editor.

-- Atomic bottle recording function.
-- Inserts the bottle, then increments user totals.
-- ON CONFLICT on barcode means scanning the same barcode twice never double-counts.
create or replace function record_bottle(
  p_user_id text,
  p_bin_id text,
  p_barcode text,
  p_points int
) returns void language plpgsql security definer as $$
begin
  -- Ensure a matching users row exists (required by recycled_bottles.userId FK).
  -- Pull defaults from auth.users when available.
  insert into users (
    user_id,
    name,
    email,
    mobile,
    "totalPoints",
    "totalBottles",
    "isAdmin"
  )
  select
    p_user_id,
    coalesce(nullif(trim(au.raw_user_meta_data ->> 'name'), ''), 'User'),
    coalesce(au.email, ''),
    '',
    0,
    0,
    false
  from auth.users au
  where au.id::text = p_user_id
  on conflict (user_id) do nothing;

  insert into recycled_bottles (barcode, "userId", "binId")
  values (p_barcode, p_user_id, p_bin_id)
  on conflict (barcode) do nothing;

  -- Only increment if the insert actually happened.
  if found then
    update users
    set "totalBottles" = "totalBottles" + 1,
        "totalPoints" = "totalPoints" + p_points
    where user_id = p_user_id;
  end if;
end;
$$;

-- Allow authenticated users to call this function.
grant execute on function record_bottle(text, text, text, int)
  to authenticated;
