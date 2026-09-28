begin;

-- Keep appointment notifications distinguishable while preserving every
-- existing notification type and its current RLS behavior.
alter table public.notifications
  drop constraint if exists notifications_type_check;

alter table public.notifications
  add constraint notifications_type_check check (
    type = any (array[
      'quote'::text,
      'chosen'::text,
      'message'::text,
      'nearby_job'::text,
      'appointment_proposed'::text,
      'appointment_confirmed'::text
    ])
  );

commit;
