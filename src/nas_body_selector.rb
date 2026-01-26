require_relative 'mesh_loader'
path = "work_dir/meshes/rod4.nas"

mesh = Mesh.load_from_nas(path)
out_path = "work_dir/mesh_new.nas"

mesh.save_to_nas(out_path)