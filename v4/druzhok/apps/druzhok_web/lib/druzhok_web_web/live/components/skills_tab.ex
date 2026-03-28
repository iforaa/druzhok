defmodule DruzhokWebWeb.Live.Components.SkillsTab do
  use Phoenix.Component

  attr :skills, :list, default: []
  attr :instance_name, :string, required: true
  attr :editing_skill, :any, default: nil

  def skills_tab(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <h3 class="text-sm font-semibold mb-3">Skills</h3>
        <div :if={@skills == []} class="text-sm text-gray-400">
          No skills yet. Create one below or let the bot create its own.
        </div>
        <div :for={skill <- @skills} class="flex items-center justify-between py-2 border-b border-gray-100 last:border-0">
          <div>
            <div class="text-sm font-medium">
              <%= skill.name %>
              <span :if={skill.pending} class="ml-2 text-xs text-amber-600 font-medium">Pending</span>
              <span :if={!skill.enabled} class="ml-2 text-xs text-gray-400 font-medium">Disabled</span>
            </div>
            <div class="text-xs text-gray-400"><%= skill.description %></div>
          </div>
          <div class="flex items-center gap-2">
            <button :if={skill.pending} phx-click="approve_skill" phx-value-name={@instance_name} phx-value-skill={skill.dir}
                    class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-3 py-1 text-xs font-medium transition">
              Approve
            </button>
            <button phx-click="toggle_skill" phx-value-name={@instance_name} phx-value-skill={skill.dir} phx-value-enabled={"#{!skill.enabled}"}
                    class="text-xs text-blue-600 hover:underline">
              <%= if skill.enabled, do: "Disable", else: "Enable" %>
            </button>
            <button phx-click="edit_skill" phx-value-name={@instance_name} phx-value-skill={skill.dir}
                    class="text-xs text-blue-600 hover:underline">Edit</button>
            <button phx-click="delete_skill" phx-value-name={@instance_name} phx-value-skill={skill.dir}
                    data-confirm="Delete this skill?" class="text-xs text-red-600 hover:underline">Delete</button>
          </div>
        </div>
      </div>

      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <h3 class="text-sm font-semibold mb-3">
          <%= if @editing_skill, do: "Edit Skill: #{@editing_skill.dir}", else: "Create Skill" %>
        </h3>
        <form phx-submit="save_skill" class="space-y-3">
          <input type="hidden" name="instance_name" value={@instance_name} />
          <input type="hidden" name="original_dir" value={@editing_skill && @editing_skill.dir} />
          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="block text-xs text-gray-500 mb-1">Name (lowercase, a-z, 0-9, hyphens)</label>
              <input name="skill_name" value={@editing_skill && @editing_skill.dir}
                     pattern="[a-z0-9][a-z0-9_-]*" required
                     class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">Description</label>
              <input name="description" value={@editing_skill && @editing_skill.description}
                     required class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm" />
            </div>
          </div>
          <div>
            <label class="block text-xs text-gray-500 mb-1">Content (markdown body after frontmatter)</label>
            <textarea name="content" rows="10" required
                      class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono resize-y"><%= @editing_skill && @editing_skill.body %></textarea>
          </div>
          <div class="flex items-center gap-3">
            <button type="submit" class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-4 py-2 text-sm font-medium transition">
              <%= if @editing_skill, do: "Update", else: "Create" %>
            </button>
            <button :if={@editing_skill} type="button" phx-click="cancel_edit_skill"
                    class="text-sm text-gray-500 hover:text-gray-900">Cancel</button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
