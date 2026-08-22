package main
import la "core:math/linalg"
import "core:math"

Node :: struct {
    translation:    Vec3,
    scale:          Vec3,
    rotation:       quaternion128,
    transform:      matrix[4,4]f32,
    mesh_id:        u32,
    parent_id:      u32,
    next_sibling_id:u32,
    first_child_id: u32,
    dirty:          bool,
}

getTransform :: proc(node: ^Node) -> matrix[4, 4]f32 {
	if node.dirty {
		mat_translate := la.matrix4_translate(node.translation)
		mat_rotate := la.matrix4_from_quaternion_f32(node.rotation)
		mat_scale := la.matrix4_scale(node.scale)
		node.transform = mat_translate * mat_rotate * mat_scale
		node.dirty = false
	}
	return node.transform
}

setTranslation :: proc(node: ^Node, translation: Vec3) {
	node.translation = translation
	node.dirty = true
}

setRotation :: proc(node: ^Node, rotation: quaternion128) {
	node.rotation = rotation
	node.dirty = true
}

setScale :: proc(node: ^Node, scale: Vec3) {
	node.scale = scale
	node.dirty = true
}

setTransform :: proc(node: ^Node, transform: matrix[4, 4]f32) {
	node.translation = Vec3{transform[0, 3], transform[1, 3], transform[2, 3]}

	col0 := Vec3{transform[0, 0], transform[1, 0], transform[2, 0]}
	col1 := Vec3{transform[0, 1], transform[1, 1], transform[2, 1]}
	col2 := Vec3{transform[0, 2], transform[1, 2], transform[2, 2]}
	sx, sy, sz := la.length(col0), la.length(col1), la.length(col2)
	node.scale = Vec3{sx, sy, sz}

	// normalize the columns to isolate the pure-rotation part
	r0 := col0 / sx
	r1 := col1 / sy
	r2 := col2 / sz
	m := matrix[3, 3]f32{
		r0.x, r1.x, r2.x,
		r0.y, r1.y, r2.y,
		r0.z, r1.z, r2.z,
	}
	node.rotation = quaternion128(quaternion_from_matrix3(m))

	node.transform = transform
	node.dirty = false
}

// standard trace-based rotation-matrix -> quaternion conversion
quaternion_from_matrix3 :: proc(m: matrix[3, 3]f32) -> quaternion256 {
	trace := m[0, 0] + m[1, 1] + m[2, 2]
	x, y, z, w: f32
	if trace > 0 {
		s := math.sqrt(trace + 1) * 2
		w = 0.25 * s
		x = (m[2, 1] - m[1, 2]) / s
		y = (m[0, 2] - m[2, 0]) / s
		z = (m[1, 0] - m[0, 1]) / s
	} else if m[0, 0] > m[1, 1] && m[0, 0] > m[2, 2] {
		s := math.sqrt(1 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
		w = (m[2, 1] - m[1, 2]) / s
		x = 0.25 * s
		y = (m[0, 1] + m[1, 0]) / s
		z = (m[0, 2] + m[2, 0]) / s
	} else if m[1, 1] > m[2, 2] {
		s := math.sqrt(1 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
		w = (m[0, 2] - m[2, 0]) / s
		x = (m[0, 1] + m[1, 0]) / s
		y = 0.25 * s
		z = (m[1, 2] + m[2, 1]) / s
	} else {
		s := math.sqrt(1 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
		w = (m[1, 0] - m[0, 1]) / s
		x = (m[0, 2] + m[2, 0]) / s
		y = (m[1, 2] + m[2, 1]) / s
		z = 0.25 * s
	}
	return quaternion(real=w, imag= x, jmag= y, kmag=z)
}

NodeWorld :: struct {
	nodes:     [dynamic]Node,
	max_nodes: int,
}

nodeWorldInit :: proc(nw: ^NodeWorld, max_nodes: int) {
	nw.max_nodes = max_nodes
	nw.nodes = make([dynamic]Node, 0, max_nodes)
}

createNode :: proc(nw: ^NodeWorld) -> (^Node, u32) {
	assert(len(nw.nodes) < nw.max_nodes, "Node world is at capacity")
	append(&nw.nodes, Node{})
	node_id := u32(len(nw.nodes))
	return &nw.nodes[node_id - 1], node_id
}

getNode :: proc(nw: ^NodeWorld, node_id: u32) -> ^Node {
	assert(node_id > 0, "Tried retrieving a node with nil ID")
	return &nw.nodes[node_id - 1]
}
