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
function bestPointString(names, values) {
    let result = "";
    names.forEach((name, index) => (
        result += `${name}: ${values[index].toFixed(4)}, `
    ))
    return result;
}
// Отображение деталей кэша
function displayCacheDetails(cache) {
    const detailsElement = document.getElementById('cache-details');

    let paramSelectors = '';
    if (cache.dimension > 2) {
        paramSelectors = `
        <div class="row mb-3">
            <div class="col-md-6">
                <label for="param-x-select"><strong>Параметр X:</strong></label>
                <select id="param-x-select" class="form-select"></select>
            </div>
            <div class="col-md-6">
                <label for="param-y-select"><strong>Параметр Y:</strong></label>
                <select id="param-y-select" class="form-select"></select>
            </div>
        </div>
        `;
    }

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
                            <li><strong>Лучшая точка:</strong> ${bestPointString(cache.parameter_names, cache.statistics.best_point)}</li>
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
                ${paramSelectors}
                <!-- График -->
                <div class="row">
                    <div class="col-md-12">
                        <h6>Визуализация</h6>
                        <div id="optimization-plot" style="width: 100%; height: 600px;"></div>
                    </div>
                </div>
                <!-- График истории улучшений -->
                <div class="row mt-4">
                    <div class="col-md-12">
                        <h6>История лучших значений фитнес-функции</h6>
                        <div id="fitness-history-plot" style="width: 100%; height: 300px;"></div>
                    </div>
                </div>
            </div>
        </div>
    `;

    detailsElement.innerHTML = html;

    // Для многомерных случаев инициализируем селекты
    if (cache.dimension > 2) {
        const paramXSelect = document.getElementById('param-x-select');
        const paramYSelect = document.getElementById('param-y-select');
        paramXSelect.innerHTML = cache.parameter_names.map((name, i) => `<option value="${i}">${name}</option>`).join('');
        paramYSelect.innerHTML = cache.parameter_names.map((name, i) => `<option value="${i}" ${i===1?'selected':''}>${name}</option>`).join('');
        // По умолчанию X=0, Y=1
        paramXSelect.value = 0;
        paramYSelect.value = 1;
        paramXSelect.onchange = paramYSelect.onchange = function() {
            drawOptimizationPlot(cache);
        };
    }

    // Строим график точек оптимизации
    drawOptimizationPlot(cache);
    // Строим график истории улучшений
    drawFitnessHistoryPlot(cache);
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
                    title: 'Значение целевой функции'
                }
            },
            text: z.map((fitness, index) =>
                `${cache.parameter_names[0]}: ${x[index].toFixed(4)}<br>` +
                `${cache.parameter_names[1]}: ${y[index].toFixed(4)}<br>` +
                `Целевая функция: ${fitness.toFixed(4)}`
            ),
            hovertemplate: '%{text}<extra></extra>'
        };

        const layout = {
            title: {
                text: 'Точки оптимизации в пространстве параметров',
                font: { size: 16 }
            },
            scene: {
                xaxis: {
                    title: {
                        text: `Параметр: ${cache.parameter_names[0]}`,
                        font: { size: 14 }
                    }
                },
                yaxis: {
                    title: {
                        text: `Параметр: ${cache.parameter_names[1]}`,
                        font: { size: 14 }
                    }
                },
                zaxis: {
                    title: {
                        text: 'Значение целевой функции',
                        font: { size: 14 }
                    }
                }
            },
            margin: { l: 0, r: 0, b: 0, t: 50 }
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
            marker: { size: 6 },
            text: y.map((fitness, index) =>
                `${cache.parameter_names[0]}: ${x[index].toFixed(4)}<br>` +
                `Целевая функция: ${fitness.toFixed(4)}`
            ),
            hovertemplate: '%{text}<extra></extra>'
        };

        const layout = {
            title: {
                text: 'Зависимость целевой функции от параметра оптимизации',
                font: { size: 16 }
            },
            xaxis: {
                title: {
                    text: `Параметр оптимизации: ${cache.parameter_names[0]}`,
                    font: { size: 14 }
                }
            },
            yaxis: {
                title: {
                    text: 'Значение целевой функции',
                    font: { size: 14 }
                }
            },
            margin: { l: 70, r: 20, b: 70, t: 50 }
        };

        Plotly.newPlot(plotDiv, [trace], layout);

    } else {
        // Для многомерных случаев - строим 3D scatter по выбранным параметрам
        const paramXSelect = document.getElementById('param-x-select');
        const paramYSelect = document.getElementById('param-y-select');
        const idxX = paramXSelect ? parseInt(paramXSelect.value) : 0;
        const idxY = paramYSelect ? parseInt(paramYSelect.value) : 1;

        // Получаем данные точек
        const x = cache.points.map(p => p.values[idxX]);
        const y = cache.points.map(p => p.values[idxY]);
        const z = cache.points.map(p => p.fitness);

        // Создаем 3D scatter
        const scatterTrace = {
            x: x,
            y: y,
            z: z,
            mode: 'markers',
            type: 'scatter3d',
            marker: {
                size: 6,
                color: z,
                colorscale: 'Viridis',
                colorbar: {
                    title: 'Fitness'
                }
            },
            text: z.map((fitness, i) =>
                `${cache.parameter_names[idxX]}: ${x[i].toFixed(4)}<br>` +
                `${cache.parameter_names[idxY]}: ${y[i].toFixed(4)}<br>` +
                `Fitness: ${fitness.toFixed(4)}`
            ),
            hovertemplate: '%{text}<extra></extra>'
        };

        const layout = {
            title: {
                text: `3D точки по выбранным параметрам`,
                font: { size: 16 }
            },
            scene: {
                xaxis: {
                    title: {
                        text: cache.parameter_names[idxX],
                        font: { size: 14 }
                    }
                },
                yaxis: {
                    title: {
                        text: cache.parameter_names[idxY],
                        font: { size: 14 }
                    }
                },
                zaxis: {
                    title: {
                        text: 'Fitness',
                        font: { size: 14 }
                    }
                }
            },
            margin: { l: 0, r: 0, b: 0, t: 50 }
        };

        Plotly.newPlot(plotDiv, [scatterTrace], layout);
    }
}

// Построение графика истории улучшений
function drawFitnessHistoryPlot(cache) {
    const plotDiv = document.getElementById('fitness-history-plot');

    if (!cache.best_fitness_history || cache.best_fitness_history.length === 0) {
        plotDiv.innerHTML = '<div class="alert alert-info">Нет данных для истории улучшений</div>';
        return;
    }

    const iterations = cache.best_fitness_history.map((_, i) => i + 1);
    const trace = {
        x: iterations,
        y: cache.best_fitness_history,
        mode: 'lines+markers',
        type: 'scatter',
        line: { width: 2, color: 'green' },
        marker: { size: 4, color: 'green' },
        text: cache.best_fitness_history.map((f, i) => `Эпоха: ${iterations[i]}<br>Лучшее значение: ${f.toFixed(4)}`),
        hovertemplate: '%{text}<extra></extra>'
    };

    const layout = {
        title: {
            text: 'История лучших значений фитнес-функции',
            font: { size: 16 }
        },
        xaxis: {
            title: {
                text: 'Эпоха',
                font: { size: 14 }
            }
        },
        yaxis: {
            title: {
                text: 'Лучшее значение фитнес-функции',
                font: { size: 14 }
            }
        },
        margin: { l: 70, r: 20, b: 70, t: 50 }
    };

    Plotly.newPlot(plotDiv, [trace], layout);
}

// Форматирование временной метки
function formatTimestamp(timestamp) {
    const date = new Date(timestamp);
    return date.toLocaleString('ru-RU');
}

// Инициализация при загрузке страницы
document.addEventListener('DOMContentLoaded', function() {
    loadCaches();
});
