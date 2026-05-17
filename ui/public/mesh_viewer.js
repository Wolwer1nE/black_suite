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
    normalScaleMultiplier: 1,
    visibleBodies: new Set(),
    defaultCamera: null,
    renderTransform: null,
    raycaster: null,
    pointer: null,
    selectedNormalNode: null,
    normalNodeBaseMaterial: null
};

const TARGET_RENDER_SIZE = 12;
const DEFAULT_NORMAL_LENGTH_RATIO = 0.12;
const DEFAULT_NORMAL_NODE_RADIUS_RATIO = 0.012;
const NORMAL_NODE_COLOR = 0xb45309;
const NORMAL_NODE_SELECTED_COLOR = 0xf97316;

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

    const grid = new THREE.GridHelper(10, 10, 0xcbd5e1, 0xe2e8f0);
    grid.position.set(0, 0, 0);
    viewerState.scene.add(grid);

    setViewerMessage('Выберите фигуру слева, чтобы построить сетку.');
    clearSelectedNodeInfo();
}

function bindControls() {
    const normalScale = document.getElementById('normal-scale');
    const normalScaleValue = document.getElementById('normal-scale-value');
    const toggleNormals = document.getElementById('toggle-normals');
    const toggleNormalNodes = document.getElementById('toggle-normal-nodes');
    const toggleEdges = document.getElementById('toggle-edges');
    const toggleTransparent3D = document.getElementById('toggle-transparent-3d');
    const fitCameraButton = document.getElementById('fit-camera');
    const showAllBodiesButton = document.getElementById('show-all-bodies');
    const hideAllBodiesButton = document.getElementById('hide-all-bodies');

    normalScale.addEventListener('input', () => {
        viewerState.normalScaleMultiplier = Number(normalScale.value);
        normalScaleValue.textContent = `${viewerState.normalScaleMultiplier.toFixed(1)}×`;
        if (viewerState.currentShape) {
            renderNormals(viewerState.currentShape);
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

    fitCameraButton.addEventListener('click', resetCameraToDefault);
    showAllBodiesButton.addEventListener('click', () => setAllBodiesVisibility(true));
    hideAllBodiesButton.addEventListener('click', () => setAllBodiesVisibility(false));

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
        <button type="button" class="shape-list-item" data-shape-id="${shape.id}">
            <div class="d-flex justify-content-between align-items-start gap-2">
                <div>
                    <div class="shape-list-title">${shape.name}</div>
                    <div class="shape-list-meta">${shape.mesh_file}</div>
                </div>
                <span class="badge text-bg-light">${shape.dimension}D</span>
            </div>
            <div class="shape-list-stats">
                ${shape.nodes_count} узлов · ${shape.elements_count} элементов · ${shape.normals_count} нормалей
            </div>
        </button>
    `).join('');

    list.querySelectorAll('.shape-list-item').forEach(button => {
        button.addEventListener('click', () => selectShape(button.dataset.shapeId));
    });
}

function selectShape(shapeId) {
    setActiveShape(shapeId);
    setViewerMessage('Загрузка геометрии и нормалей...');

    fetch(`/api/shapes/${encodeURIComponent(shapeId)}`)
        .then(response => {
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }
            return response.json();
        })
        .then(shape => {
            viewerState.currentShape = shape;
            viewerState.visibleBodies = new Set(getShapeBodyIds(shape));
            clearSelectedNormalNode();
            document.getElementById('shape-title').textContent = shape.name;
            updateShapeSummary(shape);
            renderShape(shape);
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

    document.getElementById('shape-meta').innerHTML = `
        <div><strong>${shape.mesh_file}</strong></div>
        <div>Нормали: ${shape.normals_file || 'нет файла'}</div>
        <div>Оптимизируемые узлы: ${optimizableNodesCount}</div>
        <div>Типы элементов: ${shape.element_types.join(', ')}</div>
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

function renderShape(shape) {
    clearGroup(viewerState.meshGroup);
    clearGroup(viewerState.edgeGroup);
    clearGroup(viewerState.normalVectorsGroup);
    clearGroup(viewerState.normalNodesGroup);

    viewerState.renderTransform = createRenderTransform(shape);
    const nodesById = new Map(shape.nodes.map(node => [node.id, transformCoords(node.coords, viewerState.renderTransform)]));
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

        const material = new THREE.MeshStandardMaterial({
            color: colorForBody(bodyId),
            side: THREE.DoubleSide,
            transparent: true,
            opacity: 0.92,
            roughness: 0.72,
            metalness: 0.08
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

    renderNormals(shape);
    fitCameraToShape(shape);
    updateMeshTransparency();
    applyBodyVisibility();
    clearSelectedNodeInfo();
    setViewerMessage(`Загружено: ${shape.name}. Вращайте сцену мышью, масштабируйте колесом.`);
}

function renderNormals(shape) {
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

    shape.normals.forEach(normal => {
        const start = transformCoords(normal.coords, transform);
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

function fitCameraToShape(shape) {
    const transform = viewerState.renderTransform || createRenderTransform(shape);
    if (!transform) {
        return;
    }

    const center = new THREE.Vector3(0, 0, 0);
    const size = new THREE.Vector3(transform.renderSize[0], transform.renderSize[1], transform.renderSize[2]);
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
    const hasNormals = Array.isArray(shape.normals) && shape.normals.length > 0;
    const is3D = Number(shape.dimension) === 3;

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

    infoElement.innerHTML = `
        <div class="selected-node-grid">
            <div class="selected-node-label">Node ID</div>
            <div class="selected-node-value">${normalData.nodeId}</div>
            <div class="selected-node-label">Координаты</div>
            <div class="selected-node-value">[${normalData.coords.map(formatNumber).join(', ')}]</div>
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

function colorForBody(bodyId) {
    const numericBody = Number(bodyId || 0);
    const hue = (numericBody * 67) % 360;
    return `hsl(${hue}, 70%, 55%)`;
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

document.addEventListener('DOMContentLoaded', initViewer);
