const viewerState = {
    renderer: null,
    scene: null,
    camera: null,
    controls: null,
    meshGroup: null,
    edgeGroup: null,
    normalVectorsGroup: null,
    normalNodesGroup: null,
    summaries: [],
    currentShape: null,
    showNormals: true,
    showNormalNodes: true,
    showEdges: true,
    transparency3D: false,
    showDisplacements: false,
    normalScaleMultiplier: 1,
    displacementScaleMultiplier: 1,
    displacementAutoScale: 1,
    visibleBodies: new Set(),
    defaultCamera: null,
    renderTransform: null,
    activeRenderBounds: null,
    raycaster: null,
    pointer: null,
    selectedNormalNode: null,
    normalNodeBaseMaterial: null,
    selectedDisplacementFile: null,
    optimizationJobId: null,
    optimizationPollTimer: null
};

const TARGET_RENDER_SIZE = 12;
const DEFAULT_NORMAL_LENGTH_RATIO = 0.12;
const DEFAULT_NORMAL_NODE_RADIUS_RATIO = 0.012;
const NORMAL_NODE_COLOR = 0xb45309;
const NORMAL_NODE_SELECTED_COLOR = 0xf97316;
const BODY_COLOR_PALETTE = [0x2563eb, 0xdc2626, 0x16a34a, 0xd97706, 0x7c3aed, 0x0891b2, 0xbe185d, 0x4f46e5, 0x65a30d, 0x0f766e];

function initViewer() {
    initScene();
    bindControls();
    loadShapeList();
    window.addEventListener('resize', handleResize);
    animate();
}

function initScene() {
    const container = document.getElementById('shape-canvas');
    const width = container.clientWidth || 960;
    const height = container.clientHeight || 640;

    viewerState.scene = new THREE.Scene();
    viewerState.scene.background = new THREE.Color(0xf4f7fb);
    viewerState.raycaster = new THREE.Raycaster();
    viewerState.pointer = new THREE.Vector2();

    viewerState.camera = new THREE.PerspectiveCamera(45, width / height, 0.001, 1000);
    viewerState.camera.position.set(2.5, 2.5, 2.5);

    viewerState.renderer = new THREE.WebGLRenderer({ antialias: true });
    viewerState.renderer.setPixelRatio(window.devicePixelRatio || 1);
    viewerState.renderer.setSize(width, height);
    container.appendChild(viewerState.renderer.domElement);
    container.classList.add('interactive');

    viewerState.controls = new THREE.OrbitControls(viewerState.camera, viewerState.renderer.domElement);
    viewerState.controls.enableDamping = true;
    viewerState.controls.dampingFactor = 0.08;

    viewerState.meshGroup = new THREE.Group();
    viewerState.edgeGroup = new THREE.Group();
    viewerState.normalVectorsGroup = new THREE.Group();
    viewerState.normalNodesGroup = new THREE.Group();

    viewerState.scene.add(viewerState.meshGroup);
    viewerState.scene.add(viewerState.edgeGroup);
    viewerState.scene.add(viewerState.normalVectorsGroup);
    viewerState.scene.add(viewerState.normalNodesGroup);

    const ambientLight = new THREE.AmbientLight(0xffffff, 1.1);
    const directionalLight = new THREE.DirectionalLight(0xffffff, 1.4);
    directionalLight.position.set(3, 5, 4);
    const fillLight = new THREE.DirectionalLight(0xffffff, 0.6);
    fillLight.position.set(-4, -2, 3);

    viewerState.scene.add(ambientLight);
    viewerState.scene.add(directionalLight);
    viewerState.scene.add(fillLight);
    viewerState.scene.add(new THREE.AxesHelper(1));

    setViewerMessage('Выберите фигуру слева, чтобы построить сетку.');
    clearSelectedNodeInfo();
}

function bindControls() {
    const normalScale = document.getElementById('normal-scale');
    const normalScaleValue = document.getElementById('normal-scale-value');
    const displacementScale = document.getElementById('displacement-scale');
    const displacementScaleValue = document.getElementById('displacement-scale-value');
    const toggleDisplacements = document.getElementById('toggle-displacements');
    const displacementFileSelect = document.getElementById('displacement-file-select');
    const toggleNormals = document.getElementById('toggle-normals');
    const toggleNormalNodes = document.getElementById('toggle-normal-nodes');
    const toggleEdges = document.getElementById('toggle-edges');
    const toggleTransparent3D = document.getElementById('toggle-transparent-3d');
    const fitCameraButton = document.getElementById('fit-camera');
    const showAllBodiesButton = document.getElementById('show-all-bodies');
    const hideAllBodiesButton = document.getElementById('hide-all-bodies');
    const generateLegacyDisplacementsButton = document.getElementById('generate-displacements-legacy');
    const generateAggressiveDisplacementsButton = document.getElementById('generate-displacements-aggressive');
    const startShapeOptimizationNoneButton = document.getElementById('start-shape-optimization-none');
    const startShapeOptimizationLegacyButton = document.getElementById('start-shape-optimization-legacy');
    const startShapeOptimizationAggressiveButton = document.getElementById('start-shape-optimization-aggressive');

    normalScale.addEventListener('input', () => {
        viewerState.normalScaleMultiplier = Number(normalScale.value);
        normalScaleValue.textContent = `${viewerState.normalScaleMultiplier.toFixed(1)}×`;
        if (viewerState.currentShape) {
            renderShape(viewerState.currentShape, { resetCamera: false });
        }
    });

    displacementScale.addEventListener('input', () => {
        viewerState.displacementScaleMultiplier = Number(displacementScale.value);
        displacementScaleValue.textContent = `${viewerState.displacementScaleMultiplier.toFixed(1)}×`;
        if (viewerState.currentShape && shapeHasDisplacements(viewerState.currentShape)) {
            renderShape(viewerState.currentShape, { resetCamera: false });
        }
    });

    toggleDisplacements.addEventListener('change', () => {
        viewerState.showDisplacements = toggleDisplacements.checked;
        if (viewerState.currentShape) {
            renderShape(viewerState.currentShape, { resetCamera: false });
        }
    });

    displacementFileSelect.addEventListener('change', () => {
        viewerState.selectedDisplacementFile = displacementFileSelect.value || null;
        if (viewerState.currentShape) {
            selectShape(viewerState.currentShape.id);
        }
    });

    toggleNormals.addEventListener('change', () => {
        viewerState.showNormals = toggleNormals.checked;
        viewerState.normalVectorsGroup.visible = viewerState.showNormals;
    });

    toggleNormalNodes.addEventListener('change', () => {
        viewerState.showNormalNodes = toggleNormalNodes.checked;
        viewerState.normalNodesGroup.visible = viewerState.showNormalNodes;
    });

    toggleEdges.addEventListener('change', () => {
        viewerState.showEdges = toggleEdges.checked;
        applyBodyVisibility();
    });

    toggleTransparent3D.addEventListener('change', () => {
        viewerState.transparency3D = toggleTransparent3D.checked;
        updateMeshTransparency();
    });

    fitCameraButton.addEventListener('click', fitCameraToCurrentShape);
    showAllBodiesButton.addEventListener('click', () => setAllBodiesVisibility(true));
    hideAllBodiesButton.addEventListener('click', () => setAllBodiesVisibility(false));
    generateLegacyDisplacementsButton.addEventListener('click', () => requestGenerateDisplacements('legacy'));
    generateAggressiveDisplacementsButton.addEventListener('click', () => requestGenerateDisplacements('aggressive'));
    startShapeOptimizationNoneButton.addEventListener('click', () => requestStartShapeOptimization('none'));
    startShapeOptimizationLegacyButton.addEventListener('click', () => requestStartShapeOptimization('legacy'));
    startShapeOptimizationAggressiveButton.addEventListener('click', () => requestStartShapeOptimization('aggressive'));

    viewerState.renderer.domElement.addEventListener('click', handleViewerClick);
}

function loadShapeList() {
    fetch('/api/shapes')
        .then(response => {
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }
            return response.json();
        })
        .then(shapes => {
            viewerState.summaries = shapes;
            renderShapeList(shapes);
            if (shapes.length > 0) {
                selectShape(shapes[0].id);
            } else {
                setViewerMessage('В папке data/shapes фигуры не найдены.');
                document.getElementById('shape-stats').innerHTML = '<div class="alert alert-info mb-0">Нет доступных фигур.</div>';
            }
        })
        .catch(error => {
            document.getElementById('shape-list').innerHTML = `<div class="alert alert-danger mb-0">Ошибка загрузки списка фигур: ${error.message}</div>`;
            setViewerMessage('Не удалось получить список фигур.');
        });
}

function renderShapeList(shapes) {
    const list = document.getElementById('shape-list');

    if (!shapes.length) {
        list.innerHTML = '<div class="alert alert-info mb-0">Фигуры не найдены.</div>';
        return;
    }

    list.innerHTML = shapes.map(shape => `
        <button type="button" class="shape-list-item" data-shape-id="${shape.id}" title="${shape.name}">
            <span class="shape-list-title">${shape.name}</span>
        </button>
    `).join('');

    list.querySelectorAll('.shape-list-item').forEach(button => {
        button.addEventListener('click', () => selectShape(button.dataset.shapeId));
    });
}

function selectShape(shapeId) {
    setActiveShape(shapeId);
    setViewerMessage('Загрузка геометрии и нормалей...');

    fetch(buildShapeRequestUrl(shapeId, viewerState.selectedDisplacementFile))
        .then(response => {
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }
            return response.json();
        })
        .then(shape => {
            viewerState.currentShape = shape;
            viewerState.selectedDisplacementFile = shape.displacement_file || null;
            viewerState.visibleBodies = new Set(getShapeBodyIds(shape));
            viewerState.showDisplacements = shapeHasDisplacements(shape);
            clearSelectedNormalNode();
            document.getElementById('shape-title').textContent = shape.name;
            document.getElementById('toggle-displacements').checked = viewerState.showDisplacements;
            applySuggestedSmoothingInputs(shape);
            updateShapeSummary(shape);
            renderShape(shape);
            loadActiveOptimizationJob(shape.id);
        })
        .catch(error => {
            setViewerMessage(`Ошибка загрузки фигуры: ${error.message}`);
            document.getElementById('shape-stats').innerHTML = `<div class="alert alert-danger mb-0">${error.message}</div>`;
        });
}

function setActiveShape(shapeId) {
    document.querySelectorAll('.shape-list-item').forEach(item => {
        item.classList.toggle('active', item.dataset.shapeId === shapeId);
    });
}

function updateShapeSummary(shape) {
    const bounds = shape.bounds || { min: [0, 0, 0], max: [0, 0, 0], size: [0, 0, 0] };
    const bodyCount = Array.isArray(shape.bodies) ? shape.bodies.length : 0;
    const optimizableNodesCount = Number(shape.normals_count || (shape.normals ? shape.normals.length : 0));
    const displacementParams = shape.displacement_parameters || (shape.displacement_meta && shape.displacement_meta.parameters) || null;
    const smoothingStats = shape.smoothing_stats || (shape.displacement_stats || null);
    const displacementType = shape.displacement_type || (shape.displacement_meta && shape.displacement_meta.type) || null;
    const displacementInfo = shape.has_displacements
        ? `${shape.displacement_file || 'smoothing_displacements.json'} · ${shape.displacement_count || 0} узлов`
        : 'нет файла';
    const displacementFilesHtml = Array.isArray(shape.displacement_files) && shape.displacement_files.length
        ? `<div>Доступные displacement-файлы: ${shape.displacement_files.join(', ')}</div>`
        : '';
    const displacementParamsHtml = displacementParams
        ? `<div>Параметры displacement: iter=${formatOptionalNumber(displacementParams.iterations)}, λ=${formatOptionalNumber(displacementParams.lambda)}, μ=${formatOptionalNumber(displacementParams.mu)}, max=${formatOptionalNumber(displacementParams.max_step)}, fitness=${formatOptionalNumber(displacementParams.best_fitness)}</div>`
        : '';
    const smoothingStatsHtml = smoothingStats
        ? `<div>Характерный edge: ${formatOptionalNumber(smoothingStats.characteristic_edge_length)} · рекомендованный max step: ${formatOptionalNumber(smoothingStats.suggested_max_step)}</div>`
        : '';
    const displacementTypeHtml = displacementType
        ? `<div>Тип displacement: ${displacementType}</div>`
        : '';

    document.getElementById('shape-meta').innerHTML = `
        <div><strong>${shape.mesh_file}</strong></div>
        <div>Нормали: ${shape.normals_file || 'нет файла'}</div>
        <div>Смещения: ${displacementInfo}</div>
        ${displacementFilesHtml}
        ${displacementTypeHtml}
        <div>Оптимизируемые узлы: ${optimizableNodesCount}</div>
        <div>Типы элементов: ${shape.element_types.join(', ')}</div>
        ${displacementParamsHtml}
        ${smoothingStatsHtml}
    `;

    document.getElementById('shape-stats').innerHTML = `
        <div class="row g-3">
            <div class="col-sm-6">
                <div class="stat-card">
                    <div class="stat-label">Размерность</div>
                    <div class="stat-value">${shape.dimension}D</div>
                </div>
            </div>
            <div class="col-sm-6">
                <div class="stat-card">
                    <div class="stat-label">Тел</div>
                    <div class="stat-value">${bodyCount}</div>
                </div>
            </div>
            <div class="col-sm-6">
                <div class="stat-card">
                    <div class="stat-label">Узлов</div>
                    <div class="stat-value">${shape.nodes_count}</div>
                </div>
            </div>
            <div class="col-sm-6">
                <div class="stat-card">
                    <div class="stat-label">Элементов</div>
                    <div class="stat-value">${shape.elements_count}</div>
                </div>
            </div>
            <div class="col-sm-6">
                <div class="stat-card">
                    <div class="stat-label">Оптимизируемых узлов</div>
                    <div class="stat-value">${optimizableNodesCount}</div>
                </div>
            </div>
            <div class="col-12">
                <div class="stat-card">
                    <div class="stat-label">Габариты</div>
                    <div class="stat-value stat-value-small">Δx=${formatNumber(bounds.size[0])}, Δy=${formatNumber(bounds.size[1])}, Δz=${formatNumber(bounds.size[2])}</div>
                    <div class="text-muted small mt-1">min: [${bounds.min.map(formatNumber).join(', ')}] · max: [${bounds.max.map(formatNumber).join(', ')}]</div>
                </div>
            </div>
        </div>
    `;

    renderBodyLegend(shape);
    syncDisplacementFileSelector(shape);
    syncDisplayControls(shape);
}

function renderBodyLegend(shape) {
    const legend = document.getElementById('body-legend');
    const bodies = getShapeBodyIds(shape);

    if (!bodies.length) {
        legend.innerHTML = '<div class="text-muted">Номера тел не указаны в элементах.</div>';
        return;
    }

    legend.innerHTML = bodies.map(bodyId => `
        <button type="button" class="legend-item ${viewerState.visibleBodies.has(bodyId) ? 'active' : 'inactive'}" data-body-id="${bodyId}">
            <span class="legend-swatch" style="background:${colorForBody(bodyId)}"></span>
            <span class="legend-label">Тело ${bodyId}</span>
            <span class="legend-visibility">${viewerState.visibleBodies.has(bodyId) ? 'видимо' : 'скрыто'}</span>
        </button>
    `).join('');

    legend.querySelectorAll('.legend-item').forEach(button => {
        button.addEventListener('click', () => toggleBodyVisibility(Number(button.dataset.bodyId)));
    });
}

function renderShape(shape, options = {}) {
    clearGroup(viewerState.meshGroup);
    clearGroup(viewerState.edgeGroup);
    clearGroup(viewerState.normalVectorsGroup);
    clearGroup(viewerState.normalNodesGroup);

    viewerState.renderTransform = createRenderTransform(shape);
    viewerState.displacementAutoScale = computeDisplacementAutoScale(shape, viewerState.renderTransform);
    const displayNodes = buildDisplayNodeMap(shape);
    const nodesById = new Map([...displayNodes.entries()].map(([nodeId, coords]) => [nodeId, transformCoords(coords, viewerState.renderTransform)]));
    viewerState.activeRenderBounds = computeBoundsFromCoords([...nodesById.values()]);
    const faceBuckets = buildRenderableFaces(shape.elements);

    faceBuckets.forEach((faces, bodyId) => {
        const positions = [];
        faces.forEach(face => {
            face.forEach(nodeId => {
                const coords = nodesById.get(nodeId);
                if (coords) {
                    positions.push(coords[0], coords[1], coords[2]);
                }
            });
        });

        if (!positions.length) {
            return;
        }

        const geometry = new THREE.BufferGeometry();
        geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
        geometry.computeVertexNormals();

        const material = new THREE.MeshBasicMaterial({
            color: colorForBodyHex(bodyId),
            side: THREE.DoubleSide,
            transparent: true,
            opacity: 0.92,
            depthWrite: true
        });

        const mesh = new THREE.Mesh(geometry, material);
        mesh.userData.bodyId = Number(bodyId);
        viewerState.meshGroup.add(mesh);

        const edges = new THREE.LineSegments(
            new THREE.EdgesGeometry(geometry),
            new THREE.LineBasicMaterial({ color: 0x334155, transparent: true, opacity: 0.28 })
        );
        edges.userData.bodyId = Number(bodyId);
        viewerState.edgeGroup.add(edges);
    });

    renderNormals(shape, displayNodes);
    if (options.resetCamera !== false) {
        fitCameraToCurrentShape();
    }
    updateMeshTransparency();
    applyBodyVisibility();
    clearSelectedNodeInfo();
    setViewerMessage(buildViewerLoadedMessage(shape));
}

function renderNormals(shape, displayNodes) {
    clearGroup(viewerState.normalVectorsGroup);
    clearGroup(viewerState.normalNodesGroup);

    if (!shape.normals || !shape.normals.length) {
        viewerState.normalVectorsGroup.visible = false;
        viewerState.normalNodesGroup.visible = false;
        return;
    }

    const transform = viewerState.renderTransform || createRenderTransform(shape);
    const normalLength = TARGET_RENDER_SIZE * DEFAULT_NORMAL_LENGTH_RATIO * viewerState.normalScaleMultiplier;

    const linePositions = [];
    const sphereRadius = Math.max(TARGET_RENDER_SIZE * DEFAULT_NORMAL_NODE_RADIUS_RATIO, 0.06);
    const sphereGeometry = new THREE.SphereBufferGeometry(sphereRadius, 14, 14);
    const sphereMaterial = new THREE.MeshStandardMaterial({
        color: NORMAL_NODE_COLOR,
        roughness: 0.45,
        metalness: 0.05
    });
    viewerState.normalNodeBaseMaterial = sphereMaterial;

    const displacementLookup = Array.isArray(shape.displacements)
        ? new Map(shape.displacements.map(item => [Number(item.node_id), item]))
        : null;

    shape.normals.forEach(normal => {
        const activeCoords = displayNodes.get(normal.node_id) || normal.coords;
        const displacement = displacementLookup && displacementLookup.get(Number(normal.node_id));
        const start = transformCoords(activeCoords, transform);
        const length = Math.hypot(...normal.vector);
        const direction = length > 0
            ? normal.vector.map(component => component / length)
            : [0, 0, 0];
        const end = [
            start[0] + direction[0] * normalLength,
            start[1] + direction[1] * normalLength,
            start[2] + direction[2] * normalLength
        ];

        linePositions.push(start[0], start[1], start[2], end[0], end[1], end[2]);

        const sphere = new THREE.Mesh(sphereGeometry, sphereMaterial);
        sphere.position.set(start[0], start[1], start[2]);
        sphere.userData.normalData = {
            nodeId: normal.node_id,
            coords: [...normal.coords],
            activeCoords: [...activeCoords],
            displacement: displacement ? [...displacement.delta] : null,
            vector: [...normal.vector]
        };
        viewerState.normalNodesGroup.add(sphere);
    });

    const lineGeometry = new THREE.BufferGeometry();
    lineGeometry.setAttribute('position', new THREE.Float32BufferAttribute(linePositions, 3));
    const lineMaterial = new THREE.LineBasicMaterial({ color: 0xea580c, transparent: true, opacity: 0.9 });
    viewerState.normalVectorsGroup.add(new THREE.LineSegments(lineGeometry, lineMaterial));

    viewerState.normalVectorsGroup.visible = viewerState.showNormals;
    viewerState.normalNodesGroup.visible = viewerState.showNormalNodes;
}

function buildRenderableFaces(elements) {
    const buckets = new Map();

    elements.forEach(element => {
        const bodyId = element.body ?? 0;
        if (element.type === 'triangle') {
            addFaceToBucket(buckets, bodyId, element.node_ids);
            return;
        }

        if (element.type === 'tetrahedron' && element.node_ids.length === 4) {
            const [a, b, c, d] = element.node_ids;
            const faces = [
                [a, b, c],
                [a, b, d],
                [a, c, d],
                [b, c, d]
            ];

            faces.forEach(face => {
                addFaceToBucket(buckets, bodyId, face);
            });
        }
    });

    return buckets;
}

function addFaceToBucket(buckets, bodyId, face) {
    const key = bodyId ?? 0;
    if (!buckets.has(key)) {
        buckets.set(key, []);
    }
    buckets.get(key).push(face);
}

function fitCameraToCurrentShape() {
    const bounds = viewerState.activeRenderBounds;
    if (!bounds) {
        return;
    }

    const center = new THREE.Vector3(bounds.center[0], bounds.center[1], bounds.center[2]);
    const size = new THREE.Vector3(bounds.size[0], bounds.size[1], bounds.size[2]);
    const maxDim = Math.max(size.x, size.y, size.z, 1);
    const distance = maxDim * 2.2;

    viewerState.camera.near = Math.max(distance / 1000, 0.0001);
    viewerState.camera.far = distance * 20;
    viewerState.camera.position.set(center.x + distance, center.y + distance * 0.7, center.z + distance);
    viewerState.camera.updateProjectionMatrix();

    viewerState.controls.target.copy(center);
    viewerState.controls.update();
    viewerState.defaultCamera = {
        position: viewerState.camera.position.clone(),
        target: viewerState.controls.target.clone()
    };
}

function resetCameraToDefault() {
    if (!viewerState.defaultCamera) {
        return;
    }

    viewerState.camera.position.copy(viewerState.defaultCamera.position);
    viewerState.controls.target.copy(viewerState.defaultCamera.target);
    viewerState.camera.updateProjectionMatrix();
    viewerState.controls.update();
}

function updateMeshTransparency() {
    if (!viewerState.currentShape) {
        return;
    }

    const is3D = Number(viewerState.currentShape.dimension) === 3;
    const opacity = is3D && viewerState.transparency3D ? 0.42 : 0.92;

    viewerState.meshGroup.children.forEach(mesh => {
        if (!mesh.material) {
            return;
        }

        mesh.material.opacity = opacity;
        mesh.material.transparent = opacity < 0.999;
        mesh.material.depthWrite = opacity >= 0.9;
        mesh.material.needsUpdate = true;
    });
}

function getShapeBodyIds(shape) {
    if (Array.isArray(shape.bodies) && shape.bodies.length) {
        return shape.bodies.map(Number);
    }

    const elementBodies = Array.isArray(shape.elements)
        ? [...new Set(shape.elements.map(element => Number(element.body ?? 0)))]
        : [];

    return elementBodies.sort((left, right) => left - right);
}

function toggleBodyVisibility(bodyId) {
    if (viewerState.visibleBodies.has(bodyId)) {
        viewerState.visibleBodies.delete(bodyId);
    } else {
        viewerState.visibleBodies.add(bodyId);
    }

    applyBodyVisibility();
    renderBodyLegend(viewerState.currentShape);
}

function setAllBodiesVisibility(visible) {
    if (!viewerState.currentShape) {
        return;
    }

    const bodyIds = getShapeBodyIds(viewerState.currentShape);
    viewerState.visibleBodies = visible ? new Set(bodyIds) : new Set();
    applyBodyVisibility();
    renderBodyLegend(viewerState.currentShape);
}

function applyBodyVisibility() {
    viewerState.meshGroup.children.forEach(mesh => {
        const bodyId = Number(mesh.userData.bodyId ?? 0);
        mesh.visible = viewerState.visibleBodies.has(bodyId);
    });

    viewerState.edgeGroup.children.forEach(edge => {
        const bodyId = Number(edge.userData.bodyId ?? 0);
        edge.visible = viewerState.showEdges && viewerState.visibleBodies.has(bodyId);
    });
}

function syncDisplayControls(shape) {
    const transparencyToggle = document.getElementById('toggle-transparent-3d');
    const transparencyHint = document.getElementById('transparency-hint');
    const displacementToggle = document.getElementById('toggle-displacements');
    const displacementScale = document.getElementById('displacement-scale');
    const generateButtons = getSmoothingActionButtons();
    const optimizationButtons = getOptimizationActionButtons();
    const hasNormals = Array.isArray(shape.normals) && shape.normals.length > 0;
    const hasDisplacements = shapeHasDisplacements(shape);
    const is3D = Number(shape.dimension) === 3;
    const optimizationSupported = shape.optimization_supported !== false;

    transparencyToggle.disabled = !is3D;
    if (!is3D) {
        transparencyToggle.checked = false;
        viewerState.transparency3D = false;
        transparencyHint.textContent = 'Полупрозрачность включается только для 3D-сеток.';
    } else {
        transparencyHint.textContent = 'Для объёмных сеток проще заглянуть внутрь модели.';
    }

    document.getElementById('toggle-normals').disabled = !hasNormals;
    document.getElementById('toggle-normal-nodes').disabled = !hasNormals;
    displacementToggle.disabled = !hasDisplacements;
    displacementScale.disabled = !hasDisplacements;
    if (!hasDisplacements) {
        displacementToggle.checked = false;
        viewerState.showDisplacements = false;
        const suggestion = shape.smoothing_stats && shape.smoothing_stats.suggested_max_step
            ? ` Рекомендуемый max step для этой сетки: ${formatOptionalNumber(shape.smoothing_stats.suggested_max_step)}.`
            : '';
        setDisplacementStatus(`Файл smoothing-смещений пока не создан. Нажмите кнопку ниже, чтобы его сохранить.${suggestion}`);
    } else {
        displacementToggle.checked = viewerState.showDisplacements;
        setDisplacementStatus(`Найден ${shape.displacement_file || 'smoothing_displacements.json'} на ${shape.displacement_count || 0} узлов. Автоусиление деформации: ${viewerState.displacementAutoScale.toFixed(1)}×.`);
    }

    generateButtons.forEach(button => {
        button.disabled = !hasNormals;
    });
    optimizationButtons.forEach(button => {
        button.disabled = !optimizationSupported;
    });

    if (!optimizationSupported) {
        setOptimizationStatus(shape.optimization_support_reason || 'Для этой фигуры shape optimization недоступна.', 'warning');
        setOptimizationProgress({ progress_percent: 0, phase: 'idle', status: 'idle', recent_log_lines: ['Оптимизация отключена для текущей фигуры.'] });
    }
}

function handleViewerClick(event) {
    if (!viewerState.currentShape || !viewerState.showNormalNodes || !viewerState.normalNodesGroup.visible) {
        return;
    }

    const rect = viewerState.renderer.domElement.getBoundingClientRect();
    viewerState.pointer.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
    viewerState.pointer.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;

    viewerState.raycaster.setFromCamera(viewerState.pointer, viewerState.camera);
    const intersections = viewerState.raycaster.intersectObjects(viewerState.normalNodesGroup.children, false);

    if (!intersections.length) {
        return;
    }

    setSelectedNormalNode(intersections[0].object);
}

function setSelectedNormalNode(nodeMesh) {
    if (viewerState.selectedNormalNode === nodeMesh) {
        return;
    }

    clearSelectedNormalNode();
    viewerState.selectedNormalNode = nodeMesh;

    if (nodeMesh.material && nodeMesh.material.color) {
        nodeMesh.userData.previousMaterial = nodeMesh.material;
        nodeMesh.material = nodeMesh.material.clone();
        nodeMesh.material.color.setHex(NORMAL_NODE_SELECTED_COLOR);
        nodeMesh.material.emissive = new THREE.Color(0x7c2d12);
        nodeMesh.material.emissiveIntensity = 0.45;
    }

    renderSelectedNodeInfo(nodeMesh.userData.normalData);
}

function clearSelectedNormalNode() {
    if (!viewerState.selectedNormalNode) {
        return;
    }

    const nodeMesh = viewerState.selectedNormalNode;
    if (nodeMesh.material) {
        nodeMesh.material.dispose();
        nodeMesh.material = nodeMesh.userData.previousMaterial || viewerState.normalNodeBaseMaterial;
        delete nodeMesh.userData.previousMaterial;
    }
    viewerState.selectedNormalNode = null;
}

function renderSelectedNodeInfo(normalData) {
    const infoElement = document.getElementById('selected-node-info');
    if (!normalData) {
        clearSelectedNodeInfo();
        return;
    }

    const extraRows = [];
    if (normalData.activeCoords) {
        extraRows.push(`
            <div class="selected-node-label">Текущие координаты</div>
            <div class="selected-node-value">[${normalData.activeCoords.map(formatNumber).join(', ')}]</div>
        `);
    }
    if (normalData.displacement) {
        extraRows.push(`
            <div class="selected-node-label">Смещение</div>
            <div class="selected-node-value">[${normalData.displacement.map(formatNumber).join(', ')}]</div>
        `);
    }

    infoElement.innerHTML = `
        <div class="selected-node-grid">
            <div class="selected-node-label">Node ID</div>
            <div class="selected-node-value">${normalData.nodeId}</div>
            <div class="selected-node-label">Координаты</div>
            <div class="selected-node-value">[${normalData.coords.map(formatNumber).join(', ')}]</div>
            ${extraRows.join('')}
            <div class="selected-node-label">Нормаль</div>
            <div class="selected-node-value">[${normalData.vector.map(formatNumber).join(', ')}]</div>
        </div>
    `;
}

function clearSelectedNodeInfo() {
    document.getElementById('selected-node-info').innerHTML = '<div class="selected-node-hint">Кликните по шарику узла с нормалью, чтобы увидеть его номер, координаты и вектор нормали.</div>';
}

function createRenderTransform(shape) {
    const bounds = shape.bounds;
    if (!bounds) {
        return {
            center: [0, 0, 0],
            scale: 1,
            renderSize: [TARGET_RENDER_SIZE, TARGET_RENDER_SIZE, TARGET_RENDER_SIZE]
        };
    }

    const sourceSize = bounds.size.map(value => Number(value) || 0);
    const maxDim = Math.max(...sourceSize, 1e-9);
    const scale = TARGET_RENDER_SIZE / maxDim;

    return {
        center: bounds.center.map(value => Number(value) || 0),
        scale,
        renderSize: sourceSize.map(value => value * scale)
    };
}

function transformCoords(coords, transform) {
    return coords.map((value, index) => (value - transform.center[index]) * transform.scale);
}

function clearGroup(group) {
    const geometries = new Set();
    const materials = new Set();

    while (group.children.length > 0) {
        const child = group.children[0];
        group.remove(child);
        if (child.geometry) {
            geometries.add(child.geometry);
        }
        if (child.material) {
            if (Array.isArray(child.material)) {
                child.material.forEach(material => materials.add(material));
            } else {
                materials.add(child.material);
            }
        }
    }

    geometries.forEach(geometry => geometry.dispose());
    materials.forEach(material => material.dispose());
}

function shapeHasDisplacements(shape) {
    return Array.isArray(shape.displacements) && shape.displacements.length > 0;
}

function buildDisplayNodeMap(shape) {
    const displacementMap = viewerState.showDisplacements && shapeHasDisplacements(shape)
        ? new Map(shape.displacements.map(item => [Number(item.node_id), item.delta.map(Number)]))
        : null;
    const effectiveScale = viewerState.displacementScaleMultiplier * viewerState.displacementAutoScale;

    return new Map(shape.nodes.map(node => {
        const baseCoords = node.coords.map(Number);
        const delta = displacementMap && displacementMap.get(Number(node.id));

        if (!delta) {
            return [node.id, baseCoords];
        }

        return [
            node.id,
            [
                baseCoords[0] + delta[0] * effectiveScale,
                baseCoords[1] + delta[1] * effectiveScale,
                baseCoords[2] + delta[2] * effectiveScale
            ]
        ];
    }));
}

function computeDisplacementAutoScale(shape, transform) {
    if (!shapeHasDisplacements(shape) || !transform) {
        return 1;
    }

    const maxWorldDisplacement = shape.displacements.reduce((maxValue, item) => {
        const delta = Array.isArray(item.delta) ? item.delta.map(Number) : [0, 0, 0];
        const magnitude = Math.hypot(delta[0], delta[1], delta[2]);
        return Math.max(maxValue, magnitude);
    }, 0);

    if (maxWorldDisplacement <= 1e-12) {
        return 1;
    }

    const maxSceneDisplacement = maxWorldDisplacement * transform.scale;
    const targetSceneDisplacement = TARGET_RENDER_SIZE * 0.05;
    return Math.max(targetSceneDisplacement / maxSceneDisplacement, 1);
}

function computeBoundsFromCoords(coordsList) {
    if (!coordsList.length) {
        return {
            min: [0, 0, 0],
            max: [0, 0, 0],
            size: [1, 1, 1],
            center: [0, 0, 0]
        };
    }

    const min = [...coordsList[0]];
    const max = [...coordsList[0]];

    coordsList.forEach(coords => {
        coords.forEach((value, index) => {
            min[index] = Math.min(min[index], value);
            max[index] = Math.max(max[index], value);
        });
    });

    return {
        min,
        max,
        size: min.map((value, index) => max[index] - value),
        center: min.map((value, index) => (value + max[index]) / 2)
    };
}

function buildViewerLoadedMessage(shape) {
    if (viewerState.showDisplacements && shapeHasDisplacements(shape)) {
        return `Загружено: ${shape.name}. Смещения из файла ${shape.displacement_file || ''} применены с масштабом ${viewerState.displacementScaleMultiplier.toFixed(1)}×.`;
    }

    return `Загружено: ${shape.name}. Вращайте сцену мышью, масштабируйте колесом.`;
}

function setDisplacementStatus(message, tone = 'muted') {
    const status = document.getElementById('displacement-status');
    status.className = `small text-${tone}`;
    status.textContent = message;
}

function updateShapeSummaryCache(shape) {
    viewerState.summaries = viewerState.summaries.map(item => item.id === shape.id ? { ...item, ...shape } : item);
    renderShapeList(viewerState.summaries);
    setActiveShape(shape.id);
}

function refreshShapeSummaries() {
    return fetch('/api/shapes')
        .then(response => {
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }
            return response.json();
        })
        .then(shapes => {
            viewerState.summaries = shapes;
            renderShapeList(shapes);
            if (viewerState.currentShape) {
                setActiveShape(viewerState.currentShape.id);
            }
            return shapes;
        });
}

function buildShapeRequestUrl(shapeId, displacementFile) {
    const url = new URL(`/api/shapes/${encodeURIComponent(shapeId)}`, window.location.origin);
    if (displacementFile) {
        url.searchParams.set('displacement_file', displacementFile);
    }
    return `${url.pathname}${url.search}`;
}

function syncDisplacementFileSelector(shape) {
    const select = document.getElementById('displacement-file-select');
    const files = Array.isArray(shape.displacement_files) ? shape.displacement_files : [];

    select.innerHTML = '<option value="">автовыбор</option>';
    files.forEach(file => {
        const option = document.createElement('option');
        option.value = file;
        option.textContent = file;
        select.appendChild(option);
    });

    select.disabled = files.length === 0;
    select.value = shape.displacement_file || '';
}

function requestGenerateDisplacements(smoothingMode = 'legacy') {
    if (!viewerState.currentShape) {
        return;
    }

    const smoothingParams = readSmoothingParameters(viewerState.currentShape);

    const payload = {
        iterations: smoothingParams.iterations,
        lambda: smoothingParams.lambda,
        mu: smoothingParams.mu,
        max_step: smoothingParams.maxStep,
        smoothing_mode: smoothingMode
    };

    const modeLabel = smoothingMode === 'aggressive' ? 'агрессивные' : 'normal-only';
    setDisplacementStatus(`Считаю ${modeLabel} smoothing-смещения и сохраняю displacement JSON рядом с сеткой...`, 'primary');

    fetch(`/api/shapes/${encodeURIComponent(viewerState.currentShape.id)}/displacements`, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json'
        },
        body: JSON.stringify(payload)
    })
        .then(response => response.json().then(data => ({ ok: response.ok, status: response.status, data })))
        .then(({ ok, data }) => {
            if (!ok) {
                throw new Error(data.error || 'Не удалось создать файл смещений.');
            }

            viewerState.currentShape = data;
            viewerState.visibleBodies = new Set(getShapeBodyIds(data));
            viewerState.showDisplacements = true;
            document.getElementById('toggle-displacements').checked = true;
            updateShapeSummaryCache(data);
            updateShapeSummary(data);
            renderShape(data);
            setDisplacementStatus(`Смещения (${modeLabel}) сохранены в ${data.displacement_file || 'smoothing_displacements.json'}.`, 'success');
        })
        .catch(error => {
            setDisplacementStatus(`Ошибка: ${error.message}`, 'danger');
        });
}

function requestStartShapeOptimization(preSmoothingMode = 'none') {
    if (!viewerState.currentShape) {
        return;
    }

    if (viewerState.currentShape.optimization_supported === false) {
        setOptimizationStatus(viewerState.currentShape.optimization_support_reason || 'Для этой фигуры оптимизация формы недоступна.', 'warning');
        return;
    }

    const smoothingParams = readSmoothingParameters(viewerState.currentShape);

    const payload = {
        session_name: document.getElementById('opt-session').value.trim(),
        sigma: Number(document.getElementById('opt-sigma').value || 0.3),
        max_evaluations: Number(document.getElementById('opt-max-evals').value || 1000),
        max_generations: Number(document.getElementById('opt-max-gen').value || 500),
        workers: Number(document.getElementById('opt-workers').value || 8),
        parallel: document.getElementById('opt-parallel').checked,
        target_fitness: parseOptionalNumber(document.getElementById('opt-target').value),
        pre_smoothing_mode: preSmoothingMode,
        smooth_iterations: smoothingParams.iterations,
        smooth_lambda: smoothingParams.lambda,
        smooth_mu: smoothingParams.mu,
        smooth_max_step: smoothingParams.maxStep
    };

    const modeLabel = preSmoothingMode === 'none'
        ? 'без предсглаживания'
        : preSmoothingMode === 'aggressive'
            ? 'с новым сглаживанием'
            : 'со старым сглаживанием';

    setOptimizationStatus(`Запускаю shape optimization ${modeLabel}...`, 'primary');
    setOptimizationProgress({ progress_percent: 2, phase: 'queued', recent_log_lines: [`Подготовка запуска оптимизации ${modeLabel}...`] });

    fetch(`/api/shapes/${encodeURIComponent(viewerState.currentShape.id)}/optimization`, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json'
        },
        body: JSON.stringify(payload)
    })
        .then(response => response.json().then(data => ({ ok: response.ok, status: response.status, data })))
        .then(({ ok, data }) => {
            if (!ok) {
                throw new Error(data.error || 'Не удалось запустить оптимизацию формы.');
            }

            viewerState.optimizationJobId = data.id;
            setOptimizationStatus(data.reused ? 'Оптимизация уже выполняется, подключаюсь к текущей задаче.' : 'Оптимизация запущена. Следим за прогрессом...', data.reused ? 'warning' : 'success');
            setOptimizationProgress(data);
            startOptimizationPolling(data.id);
        })
        .catch(error => {
            setOptimizationStatus(`Ошибка запуска: ${error.message}`, 'danger');
        });
}

function loadActiveOptimizationJob(shapeId) {
    stopOptimizationPolling({ preserveState: false });

    if (viewerState.currentShape && viewerState.currentShape.optimization_supported === false) {
        setOptimizationStatus(viewerState.currentShape.optimization_support_reason || 'Для этой фигуры оптимизация формы недоступна.', 'warning');
        setOptimizationProgress({ progress_percent: 0, phase: 'idle', status: 'idle', recent_log_lines: ['Оптимизация отключена для текущей фигуры.'] });
        return;
    }

    fetch(`/api/shapes/${encodeURIComponent(shapeId)}/optimization/active`)
        .then(response => response.ok ? response.json() : null)
        .then(job => {
            if (!job) {
                resetOptimizationPanel();
                return;
            }

            viewerState.optimizationJobId = job.id;
            setOptimizationStatus('Найдена активная задача оптимизации, продолжаю мониторинг.', 'primary');
            setOptimizationProgress(job);
            startOptimizationPolling(job.id);
        })
        .catch(() => {
            resetOptimizationPanel();
        });
}

function startOptimizationPolling(jobId) {
    stopOptimizationPolling({ preserveState: true });
    viewerState.optimizationJobId = jobId;
    pollOptimizationJob();
    viewerState.optimizationPollTimer = window.setInterval(pollOptimizationJob, 2000);
}

function stopOptimizationPolling({ preserveState = true } = {}) {
    if (viewerState.optimizationPollTimer) {
        window.clearInterval(viewerState.optimizationPollTimer);
        viewerState.optimizationPollTimer = null;
    }

    if (!preserveState) {
        viewerState.optimizationJobId = null;
    }
}

function pollOptimizationJob() {
    if (!viewerState.optimizationJobId) {
        return;
    }

    fetch(`/api/shape-optimization/jobs/${encodeURIComponent(viewerState.optimizationJobId)}`)
        .then(response => response.json().then(data => ({ ok: response.ok, data })))
        .then(({ ok, data }) => {
            if (!ok) {
                throw new Error(data.error || 'Не удалось получить статус задачи.');
            }

            setOptimizationProgress(data);

            if (data.status === 'completed') {
                stopOptimizationPolling({ preserveState: true });
                setOptimizationStatus('Оптимизация завершена. Обновляю данные фигуры и displacement-файлы.', 'success');
                refreshAfterOptimization(data.shape_id);
            } else if (data.status === 'failed') {
                stopOptimizationPolling({ preserveState: true });
                setOptimizationStatus(`Оптимизация завершилась с ошибкой (код ${data.exit_code ?? '—'}).`, 'danger');
            }
        })
        .catch(error => {
            stopOptimizationPolling({ preserveState: true });
            setOptimizationStatus(`Ошибка получения статуса: ${error.message}`, 'danger');
        });
}

function refreshAfterOptimization(shapeId) {
    refreshShapeSummaries()
        .then(() => {
            if (viewerState.currentShape && viewerState.currentShape.id === shapeId) {
                return selectShape(shapeId);
            }
            return null;
        })
        .catch(error => {
            setOptimizationStatus(`Оптимизация завершилась, но обновить UI не удалось: ${error.message}`, 'warning');
        });
}

function setOptimizationStatus(message, tone = 'muted') {
    const status = document.getElementById('optimization-status');
    status.className = `small text-${tone}`;
    status.textContent = message;
}

function setOptimizationProgress(job) {
    const startButtons = getOptimizationActionButtons();
    const progressBar = document.getElementById('optimization-progress-bar');
    const progressLabel = document.getElementById('optimization-progress-label');
    const progressMeta = document.getElementById('optimization-progress-meta');
    const logElement = document.getElementById('optimization-log');
    const progress = Math.max(0, Math.min(Number(job.progress_percent || 0), 100));

    progressBar.style.width = `${progress}%`;
    progressBar.textContent = `${progress.toFixed(0)}%`;
    progressBar.setAttribute('aria-valuenow', `${progress}`);
    progressBar.classList.toggle('progress-bar-animated', !['completed', 'failed'].includes(job.status));
    progressBar.classList.toggle('bg-success', job.status === 'completed');
    progressBar.classList.toggle('bg-danger', job.status === 'failed');
    startButtons.forEach(button => {
        button.disabled = ['running', 'queued'].includes(job.status);
    });

    progressLabel.textContent = buildOptimizationProgressLabel(job);
    progressMeta.textContent = buildOptimizationProgressMeta(job);
    logElement.textContent = Array.isArray(job.recent_log_lines) && job.recent_log_lines.length
        ? job.recent_log_lines.join('\n')
        : 'Лог пока пуст.';
    logElement.scrollTop = logElement.scrollHeight;
}

function resetOptimizationPanel() {
    stopOptimizationPolling({ preserveState: false });
    setOptimizationStatus('Выберите фигуру и задайте параметры, чтобы запустить оптимизацию формы прямо из UI.');
    setOptimizationProgress({ progress_percent: 0, phase: 'idle', status: 'idle', recent_log_lines: ['Лог появится после запуска оптимизации.'] });
}

function buildOptimizationProgressLabel(job) {
    const phaseLabels = {
        queued: 'В очереди',
        extracting_boundaries: 'Извлечение границ смещений',
        optimizing: 'Идёт оптимизация',
        completed: 'Оптимизация завершена',
        failed: 'Оптимизация завершилась с ошибкой',
        idle: 'Задача ещё не запущена'
    };

    return phaseLabels[job.phase] || phaseLabels[job.status] || 'Оптимизация формы';
}

function buildOptimizationProgressMeta(job) {
    const generationPart = typeof job.current_generation === 'number' && typeof job.max_generations === 'number'
        ? `gen ${job.current_generation}/${job.max_generations}`
        : null;
    const evalPart = typeof job.current_evaluations === 'number' && typeof job.max_evaluations === 'number'
        ? `eval ${job.current_evaluations}/${job.max_evaluations}`
        : null;
    const fitnessPart = typeof job.best_fitness === 'number'
        ? `best ${formatNumber(job.best_fitness)}`
        : null;

    return [generationPart, evalPart, fitnessPart].filter(Boolean).join(' · ') || '—';
}

function applySuggestedSmoothingInputs(shape) {
    const suggestedMaxStep = getSuggestedSmoothingMaxStep(shape);

    if (suggestedMaxStep === null) {
        return;
    }

    const maxStepInput = document.getElementById('smooth-max-step');
    maxStepInput.value = suggestedMaxStep.toFixed(6);
    maxStepInput.placeholder = suggestedMaxStep.toFixed(6);
}

function readSmoothingParameters(shape) {
    const iterations = Number(document.getElementById('smooth-iterations').value || 3);
    const lambda = Number(document.getElementById('smooth-lambda').value || 0.25);
    const muRaw = document.getElementById('smooth-mu').value;
    const maxStepInput = document.getElementById('smooth-max-step');
    const maxStepRaw = maxStepInput.value;
    const suggestedMaxStep = getSuggestedSmoothingMaxStep(shape);
    let maxStep = parseOptionalNumber(maxStepRaw);

    if (maxStep !== null && suggestedMaxStep !== null) {
        const isLegacyDefault = Math.abs(maxStep - 0.0005) <= 1e-12;
        const isMuchLargerThanSuggested = maxStep > suggestedMaxStep * 5;

        if (isLegacyDefault && isMuchLargerThanSuggested) {
            maxStep = suggestedMaxStep;
            maxStepInput.value = suggestedMaxStep.toFixed(6);
        }
    }

    return {
        iterations,
        lambda,
        mu: parseOptionalNumber(muRaw),
        maxStep
    };
}

function getSmoothingActionButtons() {
    return [
        document.getElementById('generate-displacements-legacy'),
        document.getElementById('generate-displacements-aggressive')
    ].filter(Boolean);
}

function getOptimizationActionButtons() {
    return [
        document.getElementById('start-shape-optimization-none'),
        document.getElementById('start-shape-optimization-legacy'),
        document.getElementById('start-shape-optimization-aggressive')
    ].filter(Boolean);
}

function getSuggestedSmoothingMaxStep(shape) {
    return shape && shape.smoothing_stats && typeof shape.smoothing_stats.suggested_max_step === 'number'
        ? shape.smoothing_stats.suggested_max_step
        : null;
}

function parseOptionalNumber(value) {
    const trimmed = String(value || '').trim();
    if (!trimmed) {
        return null;
    }

    const parsed = Number(trimmed);
    return Number.isFinite(parsed) ? parsed : null;
}

function handleResize() {
    const container = document.getElementById('shape-canvas');
    if (!container || !viewerState.renderer || !viewerState.camera) {
        return;
    }

    const width = container.clientWidth || 960;
    const height = container.clientHeight || 640;
    viewerState.camera.aspect = width / height;
    viewerState.camera.updateProjectionMatrix();
    viewerState.renderer.setSize(width, height);
}

function animate() {
    requestAnimationFrame(animate);
    if (viewerState.controls) {
        viewerState.controls.update();
    }
    if (viewerState.renderer && viewerState.scene && viewerState.camera) {
        viewerState.renderer.render(viewerState.scene, viewerState.camera);
    }
}

function colorForBodyHex(bodyId) {
    const numericBody = Math.abs(Number(bodyId || 0));
    return BODY_COLOR_PALETTE[numericBody % BODY_COLOR_PALETTE.length];
}

function colorForBody(bodyId) {
    return `#${colorForBodyHex(bodyId).toString(16).padStart(6, '0')}`;
}

function setViewerMessage(message) {
    document.getElementById('viewer-message').textContent = message;
}

function formatNumber(value) {
    if (typeof value !== 'number' || Number.isNaN(value)) {
        return '0';
    }
    return Math.abs(value) >= 1 ? value.toFixed(4) : value.toExponential(2);
}

function formatOptionalNumber(value) {
    return typeof value === 'number' && !Number.isNaN(value) ? formatNumber(value) : '—';
}

document.addEventListener('DOMContentLoaded', initViewer);
