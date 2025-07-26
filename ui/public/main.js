let currentCache = null;

// Загрузка списка кэшей
function loadCaches() {
    fetch('/caches')
        .then(response => response.json())
        .then(caches => {
            displayCacheList(caches);
        })
        .catch(err => {
            document.getElementById('cache-list').innerHTML =
                '<div class="alert alert-danger">Ошибка загрузки кэшей: ' + err.message + '</div>';
        });
}

// Отображение списка кэшей
function displayCacheList(caches) {
    const listElement = document.getElementById('cache-list');

    if (caches.length === 0) {
        listElement.innerHTML = '<div class="alert alert-info">Кэши не найдены</div>';
        return;
    }

    // Сортируем кэши по времени (новые сверху)
    caches.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));

    const html = caches.map(cache => `
        <div class="list-group-item list-group-item-action cache-item" 
             data-cache-id="${cache.id}" onclick="selectCache('${cache.id}')">
            <div class="d-flex w-100 justify-content-between">
                <h6 class="mb-1">${cache.file_name}</h6>
                <small class="text-muted">${formatTimestamp(cache.timestamp)}</small>
            </div>
            <p class="mb-1">
                <small class="text-muted">
                    ${cache.total_evaluations} оценок | 
                    Размерность: ${cache.dimension} | 
                    Лучший: ${cache.best_fitness ? cache.best_fitness.toFixed(2) : 'N/A'}
                </small>
            </p>
            <small class="text-muted">Файл: ${cache.comsol_file || 'N/A'}</small>
        </div>
    `).join('');

    listElement.innerHTML = html;
}

// Выбор кэша
function selectCache(cacheId) {
    // Убираем активный класс со всех элементов
    document.querySelectorAll('.cache-item').forEach(item => {
        item.classList.remove('active');
    });

    // Добавляем активный класс к выбранному элементу
    document.querySelector(`[data-cache-id="${cacheId}"]`).classList.add('active');

    // Показываем индикатор загрузки
    document.getElementById('cache-details').innerHTML = `
        <div class="text-center p-3">
            <div class="spinner-border" role="status"></div>
            <p class="mt-2">Загрузка данных кэша...</p>
        </div>
    `;

    // Загружаем детали кэша
    fetch(`/cache/${cacheId}`)
        .then(response => response.json())
        .then(cache => {
            currentCache = cache;
            displayCacheDetails(cache);
        })
        .catch(err => {
            document.getElementById('cache-details').innerHTML =
                '<div class="alert alert-danger">Ошибка загрузки данных кэша: ' + err.message + '</div>';
        });
}

// Отображение деталей кэша
function displayCacheDetails(cache) {
    const detailsElement = document.getElementById('cache-details');

    const html = `
        <div class="card">
            <div class="card-header">
                <h5 class="mb-0">Кэш: ${cache.file_name}</h5>
            </div>
            <div class="card-body">
                <!-- Основная информация -->
                <div class="row mb-4">
                    <div class="col-md-6">
                        <h6>Основная информация</h6>
                        <ul class="list-unstyled">
                            <li><strong>Время создания:</strong> ${formatTimestamp(cache.timestamp)}</li>
                            <li><strong>Общее количество оценок:</strong> ${cache.total_evaluations}</li>
                            <li><strong>Размерность:</strong> ${cache.dimension}</li>
                            <li><strong>Параметры:</strong> ${cache.parameter_names.join(', ')}</li>
                            <li><strong>COMSOL файл:</strong> ${cache.comsol_file}</li>
                        </ul>
                    </div>
                    <div class="col-md-6">
                        <h6>Статистика</h6>
                        <ul class="list-unstyled">
                            <li><strong>Лучший результат:</strong> ${cache.statistics.best_fitness.toFixed(4)}</li>
                            <li><strong>Худший результат:</strong> ${cache.statistics.worst_fitness.toFixed(4)}</li>
                            <li><strong>Средний результат:</strong> ${cache.statistics.average_fitness.toFixed(4)}</li>
                            <li><strong>Медиана:</strong> ${cache.statistics.median_fitness.toFixed(4)}</li>
                        </ul>
                    </div>
                </div>
                
                <!-- Границы поиска -->
                <div class="row mb-4">
                    <div class="col-md-12">
                        <h6>Границы поиска</h6>
                        <div class="row">
                            ${cache.parameter_names.map((name, index) => `
                                <div class="col-md-6">
                                    <strong>${name}:</strong> [${cache.mins[index]}, ${cache.maxs[index]}]
                                </div>
                            `).join('')}
                        </div>
                    </div>
                </div>
                
                <!-- График -->
                <div class="row">
                    <div class="col-md-12">
                        <h6>Визуализация</h6>
                        <div id="optimization-plot" style="width: 100%; height: 600px;"></div>
                    </div>
                </div>
            </div>
        </div>
    `;

    detailsElement.innerHTML = html;

    // Строим график
    drawOptimizationPlot(cache);
}

// Построение графика оптимизации
function drawOptimizationPlot(cache) {
    const plotDiv = document.getElementById('optimization-plot');

    if (cache.dimension === 2) {
        // Для 2D - используем scatter plot с цветовой картой
        const x = cache.points.map(p => p.values[0]);
        const y = cache.points.map(p => p.values[1]);
        const z = cache.points.map(p => p.fitness);

        const trace = {
            x: x,
            y: y,
            z: z,
            mode: 'markers',
            type: 'scatter3d',
            marker: {
                size: 5,
                color: z,
                colorscale: 'Viridis',
                colorbar: {
                    title: 'Fitness'
                }
            },
            text: z.map((fitness, index) =>
                `${cache.parameter_names[0]}: ${x[index].toFixed(4)}<br>` +
                `${cache.parameter_names[1]}: ${y[index].toFixed(4)}<br>` +
                `Fitness: ${fitness.toFixed(4)}`
            ),
            hovertemplate: '%{text}<extra></extra>'
        };

        const layout = {
            title: 'Точки оптимизации (3D)',
            scene: {
                xaxis: { title: cache.parameter_names[0] },
                yaxis: { title: cache.parameter_names[1] },
                zaxis: { title: 'Fitness' }
            },
            margin: { l: 0, r: 0, b: 0, t: 30 }
        };

        Plotly.newPlot(plotDiv, [trace], layout);

    } else if (cache.dimension === 1) {
        // Для 1D - простой line plot
        const x = cache.points.map(p => p.values[0]);
        const y = cache.points.map(p => p.fitness);

        const trace = {
            x: x,
            y: y,
            mode: 'markers',
            type: 'scatter',
            marker: { size: 6 }
        };

        const layout = {
            title: 'Точки оптимизации (2D)',
            xaxis: { title: cache.parameter_names[0] },
            yaxis: { title: 'Fitness' },
            margin: { l: 50, r: 20, b: 50, t: 30 }
        };

        Plotly.newPlot(plotDiv, [trace], layout);

    } else {
        // Для многомерных случаев - показываем fitness vs iteration
        const iterations = cache.points.map((_, index) => index);
        const fitness = cache.points.map(p => p.fitness);

        const trace = {
            x: iterations,
            y: fitness,
            mode: 'lines+markers',
            type: 'scatter',
            line: { width: 2 },
            marker: { size: 4 }
        };

        const layout = {
            title: `Прогресс оптимизации (${cache.dimension}D)`,
            xaxis: { title: 'Итерация' },
            yaxis: { title: 'Fitness' },
            margin: { l: 50, r: 20, b: 50, t: 30 }
        };

        Plotly.newPlot(plotDiv, [trace], layout);
    }
}

// Форматирование времени
function formatTimestamp(timestamp) {
    if (!timestamp) return 'N/A';
    const date = new Date(timestamp);
    return date.toLocaleString('ru-RU');
}

// Инициализация при загрузке страницы
document.addEventListener('DOMContentLoaded', function() {
    loadCaches();
});
