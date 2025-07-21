function drawSurface(file, folder = null) {
    let path = folder ? `${folder}/${file}` : file;
    fetch('/surface?file=' + encodeURIComponent(path))
        .then(response => response.json())
        .then(data => {
            if (!Array.isArray(data.x) || !Array.isArray(data.y) || !Array.isArray(data.z) || data.x.length === 0 || data.y.length === 0 || data.z.length === 0) {
                document.getElementById('surface').innerHTML = '<div class="alert alert-warning">Нет данных для построения поверхности</div>';
                return;
            }
            var layout = {
                title: { text: '3D Поверхность: ' + path },
                autosize: true,
                width: 700,
                height: 700,
                margin: { l: 65, r: 50, b: 65, t: 90 },
                scene: {
                    xaxis: {
                        title: 'X',
                        autorange: true,
                        range: [Math.min(...data.x), Math.max(...data.x)]
                    },
                    yaxis: {
                        title: 'Y',
                        autorange: true,
                        range: [Math.min(...data.y), Math.max(...data.y)]
                    },
                    zaxis: {
                        title: 'Z',
                        autorange: true
                    }
                }
            };
            Plotly.newPlot('surface', [{
                x: data.x,
                y: data.y,
                z: data.z,
                type: 'surface'
            }], layout);
        })
        .catch(err => {
            document.getElementById('surface').innerHTML = '<div class="alert alert-danger">Ошибка загрузки данных: ' + err.message + '</div>';
        });
}

function createTreeNode(node, parentFolder = null) {
    if (node.type === 'folder') {
        const div = document.createElement('div');
        //div.className = 'tree-folder';
        const nameDiv = document.createElement('div');
        nameDiv.className = 'tree-folder-name';
        nameDiv.textContent = node.name;
        div.appendChild(nameDiv);
        nameDiv.onclick = function(e) {
            e.stopPropagation();
            window.location.href = `/task/edit/${node.name}`;
        };
        const childrenDiv = document.createElement('div');
        childrenDiv.className = 'children';
        node.children.forEach(child => {
            childrenDiv.appendChild(createTreeNode(child, node.name));
        });
        div.appendChild(childrenDiv);
        return div;
    } else if (node.type === 'file') {
        const div = document.createElement('div');
        div.className = 'tree-file';
        div.textContent = node.name;
        div.onclick = function() {
            document.querySelectorAll('.tree-file')
                .forEach(el => el.classList.remove('active'));
            div.classList.add('active');
            drawSurface(node.name, parentFolder);
        };
        return div;
    }
}

function loadTree() {
    fetch('/tree')
        .then(response => response.json())
        .then(tree => {
            const list = document.getElementById('file-list');
            tree.forEach(node => {
                list.appendChild(createTreeNode(node));
            });
            // Автоматически открыть первый файл
            let firstFile = null, firstFolder = null;
            tree.some(node => {
                if (node.type === 'folder' && node.children.length > 0) {
                    firstFile = node.children[0].name;
                    firstFolder = node.name;
                    return true;
                } else if (node.type === 'file') {
                    firstFile = node.name;
                    return true;
                }
                return false;
            });
            if (firstFile) drawSurface(firstFile, firstFolder);
        });
}

document.addEventListener('DOMContentLoaded', function() {
    loadTree();
});
