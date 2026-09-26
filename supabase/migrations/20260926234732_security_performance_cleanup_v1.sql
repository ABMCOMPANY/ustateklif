-- TamIsim Sprint 2: behavior-preserving security and performance cleanup.
-- No data changes. Existing RLS semantics are retained while auth.uid() is
-- evaluated once per statement and foreign-key joins receive covering indexes.

begin;

-- Foreign-key indexes reported by the Performance Advisor. Existing primary or
-- unique indexes already cover the remaining foreign keys.
create index if not exists listing_payment_choices_customer_id_idx on public.listing_payment_choices(customer_id);
create index if not exists listing_payment_choices_promotion_id_idx on public.listing_payment_choices(promotion_id);
create index if not exists listing_payment_choices_quote_id_idx on public.listing_payment_choices(quote_id);
create index if not exists listing_photos_owner_idx on public.listing_photos(owner);
create index if not exists messages_sender_idx on public.messages(sender);
create index if not exists notifications_actor_id_idx on public.notifications(actor_id);
create index if not exists notifications_listing_id_idx on public.notifications(listing_id);
create index if not exists partner_members_user_id_idx on public.partner_members(user_id);
create index if not exists payment_events_payment_id_idx on public.payment_events(payment_id);
create index if not exists payment_transactions_quote_id_idx on public.payment_transactions(quote_id);
create index if not exists promo_redemptions_listing_id_idx on public.promo_redemptions(listing_id);
create index if not exists promo_redemptions_quote_id_idx on public.promo_redemptions(quote_id);
create index if not exists promotions_partner_id_idx on public.promotions(partner_id);
create index if not exists reports_listing_id_idx on public.reports(listing_id);
create index if not exists reports_reported_id_idx on public.reports(reported_id);
create index if not exists reports_reporter_id_idx on public.reports(reporter_id);

-- RLS init-plan cleanup. Only auth.uid() call shape changes; predicates and
-- allowed operations remain identical to the verified LIVE policies.
drop policy if exists "profil ekleme" on public.profiles;
create policy "profil ekleme" on public.profiles for insert to authenticated
with check (id = (select auth.uid()));

drop policy if exists "profil guncelleme" on public.profiles;
create policy "profil guncelleme" on public.profiles for update to authenticated
using (id = (select auth.uid()) and account_status = 'active')
with check (id = (select auth.uid()) and account_status = 'active');

drop policy if exists "ilan ekleme" on public.listings;
create policy "ilan ekleme" on public.listings for insert to authenticated
with check (
  owner = (select auth.uid()) and public.is_active_user()
  and status = 'open' and chosen_quote is null and rating is null
);

drop policy if exists "ilan guncelleme" on public.listings;
create policy "ilan guncelleme" on public.listings for update to authenticated
using (owner = (select auth.uid()))
with check (owner = (select auth.uid()));

drop policy if exists "ilan silme" on public.listings;
create policy "ilan silme" on public.listings for delete to authenticated
using (owner = (select auth.uid()) and public.is_active_user());

drop policy if exists "ilan fotografi ekleme" on public.listing_photos;
create policy "ilan fotografi ekleme" on public.listing_photos for insert to authenticated
with check (
  public.is_active_user() and owner = (select auth.uid())
  and exists (
    select 1 from public.listings l
    where l.id = listing_photos.listing_id
      and l.owner = (select auth.uid()) and l.status = 'open'
  )
);

drop policy if exists "ilan fotografi silme" on public.listing_photos;
create policy "ilan fotografi silme" on public.listing_photos for delete to authenticated
using (owner = (select auth.uid()));

drop policy if exists "engellerimi oku" on public.user_blocks;
create policy "engellerimi oku" on public.user_blocks for select to authenticated
using (blocker_id = (select auth.uid()));

drop policy if exists "kullanici engelle" on public.user_blocks;
create policy "kullanici engelle" on public.user_blocks for insert to authenticated
with check (
  public.is_active_user() and blocker_id = (select auth.uid())
  and blocked_id <> (select auth.uid())
);

drop policy if exists "engeli kaldir" on public.user_blocks;
create policy "engeli kaldir" on public.user_blocks for delete to authenticated
using (blocker_id = (select auth.uid()));

drop policy if exists "teklif okuma" on public.quotes;
create policy "teklif okuma" on public.quotes for select to authenticated
using (
  (pro = (select auth.uid()) and not public.is_blocked(
    (select auth.uid()),
    (select l.owner from public.listings l where l.id = quotes.listing_id)
  ))
  or exists (
    select 1 from public.listings l
    where l.id = quotes.listing_id and l.owner = (select auth.uid())
      and not public.is_blocked((select auth.uid()), quotes.pro)
  )
);

drop policy if exists "sikayet olustur" on public.reports;
create policy "sikayet olustur" on public.reports for insert to authenticated
with check (
  public.is_active_user() and reporter_id = (select auth.uid())
  and reported_id <> (select auth.uid())
);

drop policy if exists "mesaj ekleme" on public.messages;
create policy "mesaj ekleme" on public.messages for insert to authenticated
with check (
  public.is_active_user() and sender = (select auth.uid())
  and public.can_message_listing(listing_id)
);

drop policy if exists "bildirim guncelleme" on public.notifications;
create policy "bildirim guncelleme" on public.notifications for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

-- Supabase's historical default table grants included schema-changing and
-- destructive privileges which the browser roles never need.
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;

-- Remove DML capabilities for which no user-facing RLS path exists.
revoke delete on public.profiles from authenticated;
revoke update, delete on public.messages from authenticated;
revoke update, delete on public.quotes from authenticated;

-- Prevent clients from supplying server-managed workflow fields on creation.
revoke insert on public.account_deletion_requests from authenticated;
grant insert (user_id, reason) on public.account_deletion_requests to authenticated;

revoke insert on public.support_requests from authenticated;
grant insert (user_id, category, subject, message) on public.support_requests to authenticated;

revoke insert on public.reports from authenticated;
grant insert (reporter_id, reported_id, listing_id, reason) on public.reports to authenticated;

revoke insert on public.professional_verifications from authenticated;
grant insert (user_id, category, verification_type, document_type, storage_path)
  on public.professional_verifications to authenticated;

commit;
