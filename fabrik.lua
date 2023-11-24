
local fabrik = {}

local inspect = require "inspect"
local mgl = require "MGL"

function fabrik.lerp(a, b, t)
    return a + t * (b-a)
end

-- https://github.com/lincerely/gecko/tree/master
-- https://sean.cm/a/fabrik-algorithm-2d

function fabrik.link(length_min, length_max, speed, exponential, drag)
    return {
        length_min = length_min,
        length_max = length_max or length_min,
        length_absolute_min = length_min / 2,
        length_absolute_max = length_max * 2,
        speed = speed or 1.0,
        exponential = exponential or false,
        drag = drag or 0.0
    }
end

function fabrik.constraint(fixed, moving, angle_min, angle_max, speed, exponential, drag)
    return {
        fixed = fixed,
        moving = moving,
        angle_min = angle_min,
        angle_max = angle_max,
        speed = speed or 1.0,
        exponential = exponential or false,
        drag = drag or 0.0
    }
end

local Joint = {}
Joint.__index = Joint
fabrik.Joint = Joint

function Joint.new(pos)
    local self = setmetatable({}, Joint)
    self.neighbors = {}
    self.neighbor_count = 0
    self.influences = {}
    self.influence_count = 0
    self.constraints = {}
    self.pos = pos or mgl.vec2(0, 0)
    self.drag_translate = mgl.vec2(0, 0)
    self.drag_rotate = 0
    return self
end

function Joint:add_neighbor(joint, link)
    if self.neighbors[joint] == nil then
        -- update count
        self.neighbor_count = self.neighbor_count + 1
        joint.neighbor_count = joint.neighbor_count + 1
    end
    self.neighbors[joint] = link
    joint.neighbors[self] = link
end

function Joint:add_influence(joint, t)
    if self.influences[joint] == nil then
        -- update count
        self.influence_count = self.influence_count + 1
    end
    self.influences[joint] = t
end

function Joint:clear_influence()
    self.influences = {}
    self.influence_count = 0
end

function Joint:get_influence(joint)
    if self.influences[joint] ~= nil then
        return self.influences[joint]
    else
        return {
            pos = self.pos,
            drag_translate = mgl.vec2(0, 0),
            drag_rotate = 0
        }
    end
end

function Joint:add_constraint(constraint)
    table.insert(self.constraints, constraint)
end

function Joint:add_mutual_constraint(constraint)
    local mutual = {}
    for k, v in pairs(constraint) do
        mutual[k] = v
    end
    mutual.fixed = constraint.moving
    mutual.moving = constraint.fixed
    self:add_constraint(constraint)
    self:add_constraint(mutual)
end

function Joint:update_pos()
    if self.influence_count == 0 then return end
    local centroid = mgl.vec2(0, 0)
    local i = 0
    for joint, t in pairs(self.influences) do
        centroid = centroid + t.pos
        i = i + 1
    end
    centroid = centroid / i
    self.pos = centroid
end

function Joint:update_drag()
    local translate = mgl.vec2(0, 0)
    local translate_count = 0
    local rotate = 0
    local rotate_count = 0
    for joint, t in pairs(self.influences) do
        if t.drag_translate then
            translate = translate + t.drag_translate
            translate_count = translate_count + 1
        end
        if t.drag_rotate then
            rotate = rotate + t.drag_rotate
            rotate_count = rotate_count + 1
        end
    end
    if translate_count ~= 0 then
        translate = translate / translate_count
    end
    self.drag_translate = translate
    if rotate_count ~= 0 then
        rotate = rotate / rotate_count
    end
    self.drag_rotate = rotate
end

function Joint:update_self()
    self:update_pos()
    self:update_drag()
    self:clear_influence()
end

function Joint:influence_lengths(without, time)                                                                                                                            
    for joint, link in pairs(self.neighbors) do
        -- can use single joint or multiple joints
        if without == nil or joint ~= without and without[joint] == nil then
            local self_influence = joint:get_influence(self)
            local joint_pos = self_influence.pos
            local drag_translation = self.drag_translate * link.drag
            local drag_rotation = self.drag_rotate
            joint_pos = mgl.vec2(mgl.rotate(drag_rotation) * mgl.vec3(joint_pos + drag_translation - self.pos, 1)) + self.pos

            local to_joint = joint_pos - self.pos
            local dir_to_joint = mgl.normalize(to_joint)
            local length_to_joint = mgl.length(to_joint)
            local target_length = math.min(math.max(link.length_min, length_to_joint), link.length_max)
            local length_difference = target_length - length_to_joint
            local can_move_length = link.speed * time
            if link.exponential then
                can_move_length = can_move_length * math.abs(length_difference)
            end
            local moved_length
            if length_difference >= 0 then
                moved_length = math.min(can_move_length, length_difference)
            else
                moved_length = math.max(-can_move_length, length_difference)
            end
            local new_length = length_to_joint + moved_length
            new_length = math.min(math.max(link.length_absolute_min, new_length), link.length_absolute_max)
            local translate = moved_length * dir_to_joint
            local new_joint_pos = self.pos + new_length * dir_to_joint
            joint:add_influence(self, {
                pos = new_joint_pos,
                drag_translate = self_influence.drag_translate + translate + drag_translation,
                drag_rotate = self_influence.drag_rotate
            })
        end
    end
end

function Joint:influence_constraints(without, time)
    for i, constraint in ipairs(self.constraints) do
        if without == nil or constraint.moving ~= without and without[constraint.moving] == nil then
            local fixed_influence = constraint.fixed:get_influence(self)
            local moving_influence = constraint.moving:get_influence(self)
            local to_fixed = fixed_influence.pos - self.pos
            local to_moving = moving_influence.pos - self.pos
            local angle_to_fixed = math.atan2(to_fixed.y, to_fixed.x)
            local angle_to_moving = math.atan2(to_moving.y, to_moving.x)
            local angle_to_moving_min = (angle_to_fixed + constraint.angle_min) % (2*math.pi)
            local angle_to_moving_max = (angle_to_fixed + constraint.angle_max) % (2*math.pi)
            local angle_half = (angle_to_moving_max - angle_to_moving_min) % (2*math.pi) / 2
            local angle_mid = (angle_to_moving_max - angle_half) % (2*math.pi)
            local shifted_angle = (angle_to_moving - angle_mid) % (2*math.pi)
            local angle_difference = 0
            -- choose the nearest valid angle
            if angle_half < shifted_angle and shifted_angle < math.pi then
                angle_difference = angle_half - shifted_angle
            elseif math.pi <= shifted_angle and shifted_angle < 2*math.pi - angle_half then
                angle_difference = 2*math.pi - angle_half - shifted_angle
            end
            local can_move_angle = constraint.speed * time
            if constraint.exponential then
                can_move_angle = can_move_angle * math.abs(angle_difference)
            end
            local moved_angle
            if angle_difference >= 0 then
                moved_angle = math.min(can_move_angle, angle_difference)
            else
                moved_angle = math.max(-can_move_angle, angle_difference)
            end
            angle_to_moving = (angle_to_moving + moved_angle) % (2*math.pi)
            local to_target = mgl.length(to_moving) * mgl.vec2(math.cos(angle_to_moving), math.sin(angle_to_moving))
            constraint.moving:add_influence(self, {
                pos = self.pos + to_target,
                drag_translate = moving_influence.drag_translate + to_target - to_moving, -- small arc is like line
                drag_rotate = moving_influence.drag_rotate + moved_angle * constraint.drag
            })
        end
    end
end

function Joint:influence_all(without, time)
    self:influence_lengths(without, time)
    self:influence_constraints(without, time)
end

function Joint:influence_recursive(without, time)
    self:influence_all(without, time)
    for joint, link in pairs(self.neighbors) do
        if without == nil or joint ~= without and without[joint] == nil then
            if joint.influence_count >= joint.neighbor_count - 1 then
                joint:update_self()
                joint:influence_recursive(self, time)
            end
        end
    end
end

function Joint:finish_recursive(without, time)
    if self.influence_count and self.influence_count < self.neighbor_count - 1 then
        -- has multiple downstream joints
        -- need to update all downstream joints
        self:update_self()
        self:influence_all(self.influences, time)
        for joint, link in pairs(self.neighbors) do
            if self.influences[joint] == nil then
                joint:update_self()
                joint:influence_recursive(self, time)
            end
        end
    end
    for joint, link in pairs(self.neighbors) do
        if joint ~= without then
            joint:finish_recursive(self, time)
        end
    end
end

return fabrik
