class_name ModalFocus
extends RefCounted
## Явный круг фокуса не зависит от того, лежит модалка под Node или общим Control.
## Пересобирается до клавиши: скрытые кнопки подтверждения/сброса в круг не попадают.


static func contain(screen: Control) -> void:
	var controls: Array[Control] = []
	for node in screen.find_children("*", "Control", true, false):
		var control := node as Control
		if control.focus_mode != Control.FOCUS_ALL or not control.is_visible_in_tree():
			continue
		if control is BaseButton and (control as BaseButton).disabled:
			continue
		controls.append(control)
	if controls.is_empty():
		return
	for i in controls.size():
		var control := controls[i]
		var previous := control.get_path_to(controls[(i - 1 + controls.size()) % controls.size()])
		var following := control.get_path_to(controls[(i + 1) % controls.size()])
		control.focus_previous = previous
		control.focus_next = following
		control.focus_neighbor_top = previous
		control.focus_neighbor_left = previous
		control.focus_neighbor_bottom = following
		control.focus_neighbor_right = following
	var focused := screen.get_viewport().gui_get_focus_owner()
	if focused == null or not screen.is_ancestor_of(focused):
		controls[0].grab_focus()
