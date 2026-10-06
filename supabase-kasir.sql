-- =====================================================================
-- KASIR CV AZZAHRA MUTIARA TANI — setup database Supabase (versi 3)
-- Cara pakai: Supabase > SQL Editor > New query > tempel SEMUA isi file
-- ini > Run. Aman dijalankan ulang dan aman dijalankan di atas versi lama:
-- data yang sudah ada tidak dihapus, akun lama otomatis diberi ID.
-- =====================================================================

-- ---------- 1. TABEL ----------
create table if not exists public.profil (
  id      uuid primary key references auth.users(id) on delete cascade,
  email   text not null,
  nama    text not null,
  peran   text not null default 'karyawan',
  aktif   boolean not null default false,
  dibuat  timestamptz not null default now()
);
alter table public.profil add column if not exists kode    text;                             -- ad001, adm001, kar001, ...
alter table public.profil add column if not exists minta   text not null default 'karyawan'; -- peran yang diminta saat daftar
alter table public.profil add column if not exists dihapus boolean not null default false;
alter table public.profil add column if not exists kode_lama text;
create unique index if not exists profil_kode_unik on public.profil (kode) where kode is not null;

create table if not exists public.barang (
  kunci   text primary key,
  nama    text not null,
  ukuran  text not null default '',
  harga   numeric(12,0) not null default 0 check (harga >= 0),
  stok    numeric(12,2),                            -- kosong (null) = stok tidak dihitung
  diubah  timestamptz not null default now()
);
alter table public.barang alter column stok type numeric(12,2);   -- supaya bisa jual 0,5
-- Sejak versi 3 harga TIDAK dikunci. Kolom harga = harga ecer terakhir (acuan),
-- harga_partai = harga partai terakhir. Keduanya hanya saran untuk kasir.
alter table public.barang add column if not exists harga_partai numeric(12,0) not null default 0;

create table if not exists public.transaksi (
  id          bigint generated always as identity primary key,
  nomor       text,
  waktu       timestamptz not null default now(),
  kasir_id    uuid not null references public.profil(id),
  kasir_nama  text not null,
  pembeli     text not null default '',
  metode      text not null check (metode in ('tunai','transfer','qris')),
  total       numeric(14,0) not null,
  bayar       numeric(14,0) not null,
  kembali     numeric(14,0) not null,
  item        jsonb not null,
  batal       boolean not null default false,
  batal_oleh  text,
  batal_waktu timestamptz
);
alter table public.transaksi add column if not exists kasir_kode text not null default '';
alter table public.transaksi add column if not exists rekening   text not null default '';  -- rekening tujuan transfer
create index if not exists transaksi_waktu_idx on public.transaksi (waktu desc);

create table if not exists public.pengaturan (
  kunci text primary key,
  nilai jsonb not null
);
insert into public.pengaturan (kunci, nilai)
values ('rekening', '["IMAM WISNU","BASRI P","AZZAHRA MUTIARA TANI"]'::jsonb)
on conflict (kunci) do nothing;

-- ---------- 2. FUNGSI CEK PERAN ----------
create or replace function public.kasir_aktif() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profil where id = auth.uid() and aktif);
$$;

-- admin = pemilik (ad001) atau admin (adm...)
create or replace function public.kasir_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profil where id = auth.uid() and aktif and peran in ('pemilik','admin'));
$$;

create or replace function public.kasir_pemilik() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profil where id = auth.uid() and aktif and peran = 'pemilik');
$$;

-- nomor ID kosong terkecil untuk suatu peran: adm001..adm003, kar001..kar999
create or replace function public.kode_kosong(p_peran text) returns text
language sql stable security definer set search_path = public as $$
  select (case p_peran when 'admin' then 'adm' else 'kar' end) || lpad(min(n)::text, 3, '0')
  from generate_series(1, 999) n
  where not exists (
    select 1 from profil
    where kode = (case p_peran when 'admin' then 'adm' else 'kar' end) || lpad(n::text, 3, '0'));
$$;

-- ---------- 3. PINDAHKAN DATA VERSI 1 (kalau ada) ----------
alter table public.profil drop constraint if exists profil_peran_check;
do $$
declare v_id uuid; r record;
begin
  if not exists (select 1 from public.profil where peran = 'pemilik') then
    select id into v_id from public.profil where aktif
     order by (peran = 'admin') desc, dibuat limit 1;
    if v_id is not null then
      update public.profil set peran = 'pemilik', kode = 'ad001' where id = v_id;
    end if;
  end if;
  for r in select id, peran from public.profil
            where aktif and kode is null and peran in ('admin','karyawan') order by dibuat
  loop
    update public.profil set kode = public.kode_kosong(r.peran) where id = r.id;
  end loop;
end $$;
alter table public.profil add constraint profil_peran_check check (peran in ('pemilik','admin','karyawan'));

-- ---------- 4. KEAMANAN (RLS) ----------
alter table public.profil     enable row level security;
alter table public.barang     enable row level security;
alter table public.transaksi  enable row level security;
alter table public.pengaturan enable row level security;

-- Profil: tiap orang lihat miliknya sendiri, pemilik lihat semua.
-- Tidak ada policy ubah: akun hanya diatur lewat fungsi setujui_akun / hapus_akun.
drop policy if exists profil_lihat on public.profil;
create policy profil_lihat on public.profil for select to authenticated
  using (id = auth.uid() or public.kasir_pemilik());
drop policy if exists profil_ubah on public.profil;

drop policy if exists barang_lihat on public.barang;
create policy barang_lihat on public.barang for select to authenticated
  using (public.kasir_aktif());
drop policy if exists barang_tambah on public.barang;
create policy barang_tambah on public.barang for insert to authenticated
  with check (public.kasir_admin());
drop policy if exists barang_ubah on public.barang;
create policy barang_ubah on public.barang for update to authenticated
  using (public.kasir_admin()) with check (public.kasir_admin());
drop policy if exists barang_hapus on public.barang;
create policy barang_hapus on public.barang for delete to authenticated
  using (public.kasir_admin());

-- Karyawan hanya melihat transaksinya sendiri; admin dan pemilik melihat semua.
-- Tidak ada policy tulis: transaksi hanya dibuat lewat fungsi buat_transaksi.
drop policy if exists transaksi_lihat on public.transaksi;
create policy transaksi_lihat on public.transaksi for select to authenticated
  using (public.kasir_aktif() and (kasir_id = auth.uid() or public.kasir_admin()));

drop policy if exists pengaturan_lihat on public.pengaturan;
create policy pengaturan_lihat on public.pengaturan for select to authenticated
  using (public.kasir_aktif());
drop policy if exists pengaturan_tambah on public.pengaturan;
create policy pengaturan_tambah on public.pengaturan for insert to authenticated
  with check (public.kasir_admin());
drop policy if exists pengaturan_ubah on public.pengaturan;
create policy pengaturan_ubah on public.pengaturan for update to authenticated
  using (public.kasir_admin()) with check (public.kasir_admin());

-- ---------- 5. PROFIL: dibuat saat pertama login ----------
-- Akun PERTAMA otomatis jadi pemilik (ad001). Akun berikutnya menunggu
-- disetujui pemilik; ID baru diberikan saat disetujui.
drop function if exists public.pastikan_profil(text);
create or replace function public.pastikan_profil(p_nama text default '', p_minta text default 'karyawan')
returns public.profil
language plpgsql security definer set search_path = public as $$
declare
  v       public.profil;
  v_email text;
  v_awal  boolean;
begin
  if auth.uid() is null then raise exception 'Belum login'; end if;
  select * into v from profil where id = auth.uid();
  if found then return v; end if;

  lock table profil in share row exclusive mode;
  select * into v from profil where id = auth.uid();
  if found then return v; end if;

  select email into v_email from auth.users where id = auth.uid();
  v_awal := not exists (select 1 from profil);
  insert into profil (id, email, nama, peran, aktif, kode, minta)
  values (
    auth.uid(),
    coalesce(v_email, ''),
    left(coalesce(nullif(trim(p_nama), ''), split_part(coalesce(v_email, 'Pengguna'), '@', 1)), 60),
    case when v_awal then 'pemilik' else 'karyawan' end,
    v_awal,
    case when v_awal then 'ad001' else null end,
    case when p_minta = 'admin' then 'admin' else 'karyawan' end
  )
  returning * into v;
  return v;
end;
$$;

-- ---------- 6. ATUR AKUN (pemilik saja) ----------
-- Setujui akun (atau aktifkan lagi akun yang pernah dihapus) dan beri ID kosong terkecil.
create or replace function public.setujui_akun(p_id uuid, p_peran text)
returns public.profil
language plpgsql security definer set search_path = public as $$
declare v public.profil; v_kode text;
begin
  if not public.kasir_pemilik() then raise exception 'Hanya pemilik (ad001) yang bisa mengatur akun.'; end if;
  if p_peran is null or p_peran not in ('admin','karyawan') then raise exception 'Peran tidak dikenal.'; end if;
  lock table profil in share row exclusive mode;
  select * into v from profil where id = p_id;
  if not found then raise exception 'Akun tidak ditemukan.'; end if;
  if v.peran = 'pemilik' then raise exception 'Akun pemilik tidak bisa diubah.'; end if;
  if v.aktif and v.peran = p_peran then return v; end if;
  if p_peran = 'admin' and (select count(*) from profil where aktif and peran = 'admin') >= 3 then
    raise exception 'ID admin sudah penuh (maksimal 3). Hapus satu admin dulu.';
  end if;
  update profil set kode = null where id = p_id;      -- lepas ID lama dulu (kalau ganti peran)
  v_kode := public.kode_kosong(p_peran);
  if v_kode is null then raise exception 'ID untuk peran ini sudah habis.'; end if;
  update profil set peran = p_peran, aktif = true, dihapus = false, kode = v_kode
   where id = p_id returning * into v;
  return v;
end;
$$;

-- Hapus akun: akun dimatikan dan ID-nya dilepas supaya bisa dipakai orang baru.
-- Riwayat penjualannya tetap ada.
create or replace function public.hapus_akun(p_id uuid)
returns public.profil
language plpgsql security definer set search_path = public as $$
declare v public.profil;
begin
  if not public.kasir_pemilik() then raise exception 'Hanya pemilik (ad001) yang bisa mengatur akun.'; end if;
  select * into v from profil where id = p_id;
  if not found then raise exception 'Akun tidak ditemukan.'; end if;
  if v.peran = 'pemilik' then raise exception 'Akun pemilik tidak bisa dihapus.'; end if;
  update profil set aktif = false, dihapus = true, kode_lama = coalesce(kode, kode_lama), kode = null
   where id = p_id returning * into v;
  return v;
end;
$$;

-- ---------- 7. SIMPAN TRANSAKSI ----------
-- Harga diketik kasir per barang (ecer atau partai). Yang dijaga di sini:
-- akun harus aktif, angka harus masuk akal, stok dikurangi, total dihitung ulang
-- di server, dan harga terakhir disimpan sebagai saran untuk transaksi berikutnya.
-- Barang di luar katalog memakai kunci berawalan "lain|" dan stoknya tidak dihitung.
drop function if exists public.buat_transaksi(jsonb, text, numeric, text);
create or replace function public.buat_transaksi(
  p_item jsonb, p_metode text, p_bayar numeric, p_pembeli text default '', p_rekening text default ''
) returns public.transaksi
language plpgsql security definer set search_path = public as $$
declare
  v_p     public.profil;
  v_b     public.barang;
  v_t     public.transaksi;
  r       record;
  v_ada   boolean;
  v_total numeric := 0;
  v_sub   numeric;
  v_item  jsonb := '[]'::jsonb;
  v_bayar numeric;
begin
  select * into v_p from profil where id = auth.uid() and aktif;
  if not found then raise exception 'Akun belum aktif.'; end if;
  if p_metode is null or p_metode not in ('tunai','transfer','qris') then
    raise exception 'Metode bayar tidak dikenal.';
  end if;
  if p_item is null or jsonb_typeof(p_item) <> 'array' or jsonb_array_length(p_item) = 0 then
    raise exception 'Keranjang kosong.';
  end if;
  if jsonb_array_length(p_item) > 200 then raise exception 'Terlalu banyak barang dalam satu transaksi.'; end if;
  if (select count(distinct e->>'kunci') from jsonb_array_elements(p_item) e) <> jsonb_array_length(p_item) then
    raise exception 'Ada barang yang tertulis dua kali di keranjang.';
  end if;

  for r in
    select e->>'kunci' as kunci,
           left(trim(coalesce(e->>'nama', '')), 80)   as nama,
           left(trim(coalesce(e->>'ukuran', '')), 40) as ukuran,
           round((e->>'qty')::numeric, 2)             as qty,
           round((e->>'harga')::numeric)              as harga,
           case when e->>'tipe' = 'partai' then 'partai' else 'ecer' end as tipe
    from jsonb_array_elements(p_item) e
    order by 1
  loop
    if r.kunci is null or length(r.kunci) < 2 or length(r.kunci) > 160 or r.nama = '' then
      raise exception 'Data barang tidak lengkap.';
    end if;
    if r.qty is null or r.qty <= 0 or r.qty > 100000 then
      raise exception 'Jumlah "%" tidak valid.', r.nama;
    end if;
    if r.harga is null or r.harga <= 0 or r.harga > 1000000000 then
      raise exception 'Harga "%" belum diisi.', r.nama;
    end if;

    select * into v_b from barang where kunci = r.kunci for update;
    v_ada := found;
    if v_ada and v_b.stok is not null then
      if v_b.stok < r.qty then
        raise exception 'Stok % % tinggal %.', v_b.nama, v_b.ukuran,
          trim(trailing '.' from trim(trailing '0' from v_b.stok::text));
      end if;
    end if;

    -- simpan harga terakhir sebagai saran, sekaligus kurangi stok kalau dihitung
    if v_ada then
      update barang
         set stok         = case when stok is null then null else stok - r.qty end,
             harga        = case when r.tipe = 'ecer'   then r.harga else harga end,
             harga_partai = case when r.tipe = 'partai' then r.harga else harga_partai end,
             diubah       = now()
       where kunci = r.kunci;
    else
      insert into barang (kunci, nama, ukuran, harga, harga_partai)
      values (r.kunci, r.nama, r.ukuran,
              case when r.tipe = 'ecer' then r.harga else 0 end,
              case when r.tipe = 'partai' then r.harga else 0 end);
    end if;

    v_sub := round(r.harga * r.qty);
    v_total := v_total + v_sub;
    v_item := v_item || jsonb_build_object(
      'kunci', r.kunci, 'nama', r.nama, 'ukuran', r.ukuran, 'harga', r.harga, 'qty', r.qty,
      'tipe', r.tipe, 'jumlah', v_sub, 'hitung_stok', v_ada and v_b.stok is not null);
  end loop;

  if p_metode = 'tunai' then
    v_bayar := coalesce(p_bayar, 0);
    if v_bayar < v_total then raise exception 'Uang yang diterima kurang dari total.'; end if;
  else
    v_bayar := v_total;
  end if;

  insert into transaksi (kasir_id, kasir_nama, kasir_kode, pembeli, metode, rekening, total, bayar, kembali, item)
  values (v_p.id, v_p.nama, coalesce(v_p.kode, ''), left(coalesce(trim(p_pembeli), ''), 60), p_metode,
          case when p_metode = 'transfer' then left(coalesce(trim(p_rekening), ''), 60) else '' end,
          v_total, v_bayar, v_bayar - v_total, v_item)
  returning * into v_t;

  update transaksi
     set nomor = 'AMT-' || to_char(v_t.waktu at time zone 'Asia/Makassar', 'YYMMDD') || '-' || lpad(v_t.id::text, 4, '0')
   where id = v_t.id
  returning * into v_t;
  return v_t;
end;
$$;

-- ---------- 8. BATALKAN TRANSAKSI (admin/pemilik, stok dikembalikan) ----------
create or replace function public.batalkan_transaksi(p_id bigint)
returns public.transaksi
language plpgsql security definer set search_path = public as $$
declare
  v_p public.profil;
  v_t public.transaksi;
  r   record;
begin
  select * into v_p from profil where id = auth.uid() and aktif and peran in ('pemilik','admin');
  if not found then raise exception 'Hanya admin yang bisa membatalkan transaksi.'; end if;
  select * into v_t from transaksi where id = p_id for update;
  if not found then raise exception 'Transaksi tidak ditemukan.'; end if;
  if v_t.batal then raise exception 'Transaksi ini sudah dibatalkan.'; end if;

  for r in
    select e->>'kunci' as kunci, (e->>'qty')::numeric as qty
    from jsonb_array_elements(v_t.item) e
    where coalesce((e->>'hitung_stok')::boolean, false)
  loop
    update barang set stok = stok + r.qty, diubah = now()
     where kunci = r.kunci and stok is not null;
  end loop;

  update transaksi set batal = true, batal_oleh = v_p.nama, batal_waktu = now()
   where id = p_id
  returning * into v_t;
  return v_t;
end;
$$;

-- ---------- 9. IZIN ----------
revoke update on public.profil from authenticated;
grant select on public.profil to authenticated;
grant select, insert, update, delete on public.barang to authenticated;
grant select on public.transaksi to authenticated;
grant select, insert, update on public.pengaturan to authenticated;
revoke all on function public.pastikan_profil(text, text) from public, anon;
revoke all on function public.setujui_akun(uuid, text) from public, anon;
revoke all on function public.hapus_akun(uuid) from public, anon;
revoke all on function public.buat_transaksi(jsonb, text, numeric, text, text) from public, anon;
revoke all on function public.batalkan_transaksi(bigint) from public, anon;
grant execute on function public.pastikan_profil(text, text) to authenticated;
grant execute on function public.setujui_akun(uuid, text) to authenticated;
grant execute on function public.hapus_akun(uuid) to authenticated;
grant execute on function public.buat_transaksi(jsonb, text, numeric, text, text) to authenticated;
grant execute on function public.batalkan_transaksi(bigint) to authenticated;
grant execute on function public.kasir_aktif() to authenticated;
grant execute on function public.kasir_admin() to authenticated;
grant execute on function public.kasir_pemilik() to authenticated;
grant execute on function public.kode_kosong(text) to authenticated;

-- beri tahu API Supabase bahwa bentuk fungsinya berubah
notify pgrst, 'reload schema';
