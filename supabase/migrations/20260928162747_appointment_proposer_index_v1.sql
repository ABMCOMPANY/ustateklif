begin;

create index if not exists listing_appointments_proposed_by_idx
  on public.listing_appointments(proposed_by);

commit;
