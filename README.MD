# Black suite

Модуль для параметрической оптимизации конечно-элементных моделей.

Установка зависимостей:

```bash
bundle install
```

## Скрипты оптимизации

### 1. Параметрическая оптимизация (COMSOL)

Запуск из каталога black_suite:

```bash
ruby comsol_optimization.rb config.json
```

### 2. Оптимизация формы (CMA-ES)

Оптимизация формы МКЭ через движение узлов по нормалям:

```bash
ruby shape_optimization.rb <mesh_file> [options]
```

**Опции:**
- `--session NAME` — имя сессии
- `--sigma FLOAT` — начальный размер шага CMA-ES (по умолчанию: 0.3)
- `--max-evals INT` — максимум вычислений fitness (по умолчанию: 1000)
- `--max-gen INT` — максимум поколений (по умолчанию: 500)
- `--target FLOAT` — целевое значение fitness для остановки

**Пример:**
```bash
ruby shape_optimization.rb work_dir/meshes/rod4.nas --sigma 0.2 --max-evals 500
```

**Как работает:**
1. Извлечение границ смещений через `acli bs-shift-boundary`
2. Запуск CMA-ES оптимизации
3. Каждое вычисление fitness: вызов `bs-form-opt` с текущими коэффициентами
4. Результаты сохраняются в `data/<session>/`

## Конфигурационный файл
```
{
  "strategy": {
      "max_generations": 20,
      "population_size": 20,
      "crossover_prob": 0.8,
      "mutation_prob": 0.1,
      "tournament_size": 3,
      "elite_count": 2,
      "epsilon": 1e-6,
      "max_stagnant_epochs": 20
  },
  "parameters": {
    "mins": [0.0, 0.0001, 0.004, 0.004],
    "maxs": [0.8, 0.0005, 0.006, 0.006],
    "names": ["b", "wm", "cy", "cz"]
  },
  "comsol": {
    "file": "model_1_opt.mph",
    "method_call": "target_function",
    "work_dir": "work_dir",
    "silent_output": false
  },
  "output": {
    "cache_file": "model_1_opt_cache.json"
  }
}
```

### Параметры

### Стратегия оптимизации (`strategy`)

| Параметр | Описание |
|----------|-----------|
| `max_generations` | Максимальное количество поколений алгоритма |
| `population_size` | Размер популяции в каждом поколении |
| `crossover_prob` | Вероятность скрещивания |
| `mutation_prob` | Вероятность мутации |
| `tournament_size` | Размер турнира для селекции |
| `elite_count` | Количество элитных особей, переходящих в следующее поколение |
| `epsilon` |  |
| `max_stagnant_epochs` | Максимум эпох без улучшения до остановки |

### Параметры оптимизации (`parameters`)

| Параметр |  Описание |
|----------|-----------|
| `mins` | Минимальные значения параметров |
| `maxs` | Максимальные значения параметров |
| `names` | Список параметров |

### Настройки COMSOL (`comsol`)

| Параметр | Описание |
|----------|-----------|
| `file` | Файл модели COMSOL |
| `method_call` | Вызываемая функция в модели |
| `work_dir` | Рабочая директория |
| `silent_output` | Режим вывода |

### Выходные данные (`output`)

| Параметр | Описание |
|----------|-----------|
| `cache_file` | Файл для кэширования результатов |



## Результаты оптимизации 

Для просмотра результатов реализован web-сервер. Запуск:

```bash
cd ui
ruby app.rb
```
