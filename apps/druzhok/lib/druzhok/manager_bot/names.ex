defmodule Druzhok.ManagerBot.Names do
  @moduledoc """
  The names the superbot suggests for a new bot. Each naming prompt shows
  four, every one from a different group, so a person sees a varied set and
  two people rarely see the same one. Typing any other name still works.

  Names of existing assistants and film characters (Алиса, Маруся, Афина,
  Джой, Клод, Йода, ...) are left out on purpose.
  """

  @groups [
    female: ~w(Ася Соня Мила Варя Тося Зоя Лиза Глаша Поля Майя Ева Ника Тася Дуня Нюша),
    male: ~w(Макс Гоша Сеня Тёма Лёва Боря Федя Яша Сава Марк Жора Вася Проша Кузя Тимоха),
    pets: ~w(Дружок Кеша Барсик Пушок Рыжик Шарик Мурзик Тишка Филя Чижик Умка Жужа Клёпа Бублик Пончик Кекс),
    roles: ~w(Шеф Профессор Капитан Дворецкий Штурман Сыщик Мудрец Советник Домовой Джинн Умник Напарник),
    space: ~w(Астра Нова Вега Луна Орион Атлас Искра Комета Феникс Пиксель Квант Эхо),
    funny: ~w(Енот Бобёр Ёжик Филин Капибара Пингвин Пельмень Сырник Батон Огурчик),
    gods:
      ~w(Зевс Аполлон Гермес Гера Артемида Гелиос Прометей Орфей Икар Один Тор Локи Фрейя Ра Тот Исида Бастет Перун Велес Лада Янус Аврора Минерва Ганеша),
    thinkers:
      ~w(Сократ Платон Диоген Сенека Эпикур Пифагор Архимед Конфуций Кант Декарт Спиноза Вольтер Паскаль Ньютон Кеплер Галилей Дарвин Тесла Ада Гипатия),
    world_male: ~w(Джефф Боб Том Сэм Джек Лео Оскар Чарли Фред Финн Хьюго Феликс Отто Пьер Пабло Диего Лука Хиро Амир Свен),
    world_female: ~w(Эмма Мия Хлоя Люси Молли Руби Белла Стелла Нора Амели Кармен Лола Фрида Астрид Сакура Зара),
    legends:
      ~w(Руна Сага Скальд Бард Друид Оракул Сфинкс Мерлин Самурай Сэнсэй Гуру Дзен Карма Тао Икигай Хюгге Амиго Маэстро Сеньор Бро)
  ]

  @doc "The whole pool, by group."
  def groups, do: @groups

  @doc "Every name in the pool."
  def all, do: Enum.flat_map(@groups, fn {_group, names} -> names end)

  @doc "Four names, each from a different group, in random order."
  def pick do
    @groups
    |> Enum.take_random(4)
    |> Enum.map(fn {_group, names} -> Enum.random(names) end)
  end
end
