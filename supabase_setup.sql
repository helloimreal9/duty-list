-- Схема базы данных для сайта «Список дежурных»
-- Откройте Supabase → SQL Editor → New query, вставьте весь файл и нажмите Run.

create table if not exists public.duty_state (
  id integer primary key check (id = 1),
  checked_names text[] not null default '{}',
  round_number integer not null default 1 check (round_number > 0),
  updated_at timestamptz not null default now()
);

insert into public.duty_state (id, checked_names, round_number)
values (1, '{}', 1)
on conflict (id) do nothing;

create table if not exists public.duty_history (
  id bigint generated always as identity primary key,
  person_name text,
  action text not null check (action in ('checked', 'unchecked', 'round_completed')),
  round_number integer not null,
  created_at timestamptz not null default now()
);

alter table public.duty_state enable row level security;
alter table public.duty_history enable row level security;

-- Публичное чтение разрешено посетителям сайта.
drop policy if exists "Anyone can read duty state" on public.duty_state;
create policy "Anyone can read duty state"
on public.duty_state for select to anon, authenticated using (true);

drop policy if exists "Anyone can read duty history" on public.duty_history;
create policy "Anyone can read duty history"
on public.duty_history for select to anon, authenticated using (true);

-- Запись состояния выполняется только через RPC-функции ниже.
revoke insert, update, delete on public.duty_state from anon, authenticated;
revoke insert, update, delete on public.duty_history from anon, authenticated;

create or replace function public.toggle_duty(p_person_name text, p_checked boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_state public.duty_state%rowtype;
  roster text[] := array[
    'Бег Самира Рустамовна',
    'Биккулов Тимур Димович',
    'Горбунова Екатерина Алексеевна',
    'Гордиенко Яна Артуровна',
    'Дерунов Богдан Вячеславович',
    'Дзюба Ярослав Борисович',
    'Дмитрова Алина',
    'Захаров Артём Алексеевич',
    'Калмыков Павел Вячеславович',
    'Каменцев Иван Вячеславович',
    'Корнеева Екатерина Евгеньевна',
    'Наумова Анастасия Андреевна',
    'Пацюкова Анастасия Александровна',
    'Писаренко Ярослав Денисович',
    'Рыбалко Дарья Михайловна',
    'Рыжих Захар Николаевич',
    'Симоненко Мария Максимовна',
    'Слаутин Матвей Артемович',
    'Соломахин Олег Владимирович',
    'Троян Анна Максимовна',
    'Фильчукова Анастасия Алексеевна',
    'Шалама́гин Арсений Алексеевич',
    'Шатова Наталья Сергеевна',
    'Шестаков Никита Сергеевич'
  ];
  new_checked text[];
  completed boolean := false;
  finished_round integer;
begin
  if p_person_name is null or not (p_person_name = any(roster)) then
    raise exception 'Имя отсутствует в списке дежурных';
  end if;

  select * into current_state
  from public.duty_state
  where id = 1
  for update;

  new_checked := current_state.checked_names;

  if p_checked then
    if not (p_person_name = any(new_checked)) then
      new_checked := array_append(new_checked, p_person_name);
      insert into public.duty_history(person_name, action, round_number)
      values (p_person_name, 'checked', current_state.round_number);
    end if;
  else
    if p_person_name = any(new_checked) then
      new_checked := array_remove(new_checked, p_person_name);
      insert into public.duty_history(person_name, action, round_number)
      values (p_person_name, 'unchecked', current_state.round_number);
    end if;
  end if;

  if cardinality(new_checked) = cardinality(roster) then
    completed := true;
    finished_round := current_state.round_number;
    insert into public.duty_history(person_name, action, round_number)
    values (null, 'round_completed', finished_round);
    update public.duty_state
    set checked_names = '{}',
        round_number = current_state.round_number + 1,
        updated_at = now()
    where id = 1;
    return jsonb_build_object(
      'round_completed', true,
      'finished_round', finished_round,
      'new_round_number', finished_round + 1
    );
  end if;

  update public.duty_state
  set checked_names = new_checked,
      updated_at = now()
  where id = 1;

  return jsonb_build_object('round_completed', false);
end;
$$;

create or replace function public.reset_duty_round()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare current_round integer;
begin
  select round_number into current_round
  from public.duty_state
  where id = 1
  for update;

  update public.duty_state
  set checked_names = '{}', updated_at = now()
  where id = 1;
  -- Ручной сброс не меняет номер круга и не удаляет историю.
end;
$$;

revoke all on function public.toggle_duty(text, boolean) from public;
grant execute on function public.toggle_duty(text, boolean) to anon, authenticated;
revoke all on function public.reset_duty_round() from public;
grant execute on function public.reset_duty_round() to anon, authenticated;

-- Включаем Realtime для моментального обновления списка и истории.
do $$
begin
  alter publication supabase_realtime add table public.duty_state;
exception when duplicate_object then null;
when undefined_object then raise notice 'Publication supabase_realtime не найдена; включите Realtime для таблиц вручную.';
end $$;

do $$
begin
  alter publication supabase_realtime add table public.duty_history;
exception when duplicate_object then null;
when undefined_object then raise notice 'Publication supabase_realtime не найдена; включите Realtime для таблиц вручную.';
end $$;
