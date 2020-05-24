require 'json'
require 'fileutils'
require 'pathname'

CurrentScrapMechanic = "C:/Program Files (x86)/Steam/steamapps/common/Scrap Mechanic"
CurrentData = "#{CurrentScrapMechanic}/Data"
CurrentSurvival = "#{CurrentScrapMechanic}/Survival"
CurrentCraftingRecipes = "#{CurrentSurvival}/CraftingRecipes"
CurrentSurvivalInventoryDescriptions = "#{CurrentSurvival}/Gui/Language/English/inventoryDescriptions.json"
CurrentSurvivalIconMap = "#{CurrentSurvival}/Gui/IconMapSurvival.xml"
CurrentObjectsDir = "#{CurrentSurvival}/Objects"

ModScrapMechanic = "."
ModData = "#{ModScrapMechanic}/Data"
ModSurvival = "#{ModScrapMechanic}/Survival"
ModCraftingRecipes = "#{ModSurvival}/CraftingRecipes"
ModObjectsDir = "#{ModSurvival}/Objects"
ModScriptsDir = "#{ModSurvival}/Scripts"
ModSurvivalInventoryDescriptions = "#{ModSurvival}/Gui/Language/English/inventoryDescriptions.json"

current_craftbot_file = "#{CurrentCraftingRecipes}/craftbot.json"
current_item_names_file = "#{CurrentCraftingRecipes}/item_names.json"
current_inventory_descriptions_file = CurrentSurvivalInventoryDescriptions
current_shape_set_entries_file = "#{CurrentObjectsDir}/Database/shapesets.json"

current_craftbot = JSON.parse File.read(current_craftbot_file)
current_item_names = JSON.parse File.read(current_item_names_file)
current_inventory_descriptions = JSON.parse File.read(current_inventory_descriptions_file)

current_shape_set_entries = JSON.parse(File.read(current_shape_set_entries_file))["shapeSetList"]

added_craftbot_file = "#{ModCraftingRecipes}/craftbot.json"
added_item_names_file = "#{ModCraftingRecipes}/item_names.json"
added_inventory_descriptions_file = ModSurvivalInventoryDescriptions

added_craftbot = JSON.parse File.read(added_craftbot_file)
added_item_names = JSON.parse File.read(added_item_names_file)
added_inventory_descriptions = JSON.parse File.read(added_inventory_descriptions_file)

added_scripts = Dir.glob "#{ModScriptsDir}/**/*.lua"
added_shape_sets = Dir.glob "#{ModObjectsDir}/**/*.json"

added_shape_set_entries = added_shape_sets.map do |file|
  shape_set_entry = Pathname.new(file).relative_path_from "Survival"
  "$SURVIVAL_DATA/#{shape_set_entry}"
end

new_craftbot = current_craftbot
new_item_names = current_item_names
new_inventory_descriptions = current_inventory_descriptions
new_shape_set_entries = current_shape_set_entries

def truncate(string)
  max = 200
  string.length > max ? "#{string[0...max]}..." : string
end

def copy_file(file)
  target_relative_path = Pathname.new(file).relative_path_from ModScrapMechanic
  target_file = Pathname.new(CurrentScrapMechanic).join target_relative_path
  target_dir = File.dirname target_file

  unless Dir.exists? target_dir
    puts "  mkdir -p #{target_dir}"
    FileUtils.mkdir_p target_dir
  end

  puts "  cp #{file} #{target_file}"
  FileUtils.cp file, target_file
end

def delete_file(file)
  target_relative_path = Pathname.new(file).relative_path_from ModScrapMechanic
  target_file = Pathname.new(CurrentScrapMechanic).join target_relative_path
  target_dir = File.dirname target_file

  if File.exists? target_file
    puts "  rm #{target_file}"
    FileUtils.rm target_file
  end

  if Dir.empty? target_dir
    puts "  rmdir #{target_dir}"
    FileUtils.rmdir target_dir
  end
end

def write_file(file, content)
  puts "\n  writing #{file}:\n  #{truncate content}"
  File.write file, content
end

if ARGV[0] == 'undo'
  puts "undoing mod\n\n"

  puts "removing scripts:\n#{added_scripts}\n\n"
  added_scripts.each do |file|
    delete_file file
  end

  puts "removing shape sets:\n#{added_shape_sets}\n\n"
  added_shape_sets.each do |file|
    delete_file file
  end

  new_shape_set_entries = current_shape_set_entries - added_shape_set_entries

  puts "removing recipes:"
  new_craftbot = current_craftbot.reject do |current_recipe|
    rejecting = added_craftbot.any? do |added_recipe|
      current_recipe["itemId"] == added_recipe["itemId"]
    end
    if rejecting
      puts "removing recipe:\n#{current_recipe["itemId"]}"
    end
    rejecting
  end
  puts "\n"

  puts "removing item names:"
  new_item_names = current_item_names.reject do |id, name|
    rejecting = added_item_names.has_key? id
    if rejecting
      puts "removing item name:\n#{[id, name]}"
    end
    rejecting
  end
else
  puts "applying mod"

  puts "\nadding scripts:\n  #{added_scripts}"
  added_scripts.each do |file|
    copy_file file
  end

  puts "\nadding shape sets:\n  #{added_shape_sets}"
  added_shape_sets.each do |file|
    copy_file file
  end

  new_shape_set_entries = (current_shape_set_entries + added_shape_set_entries).uniq

  puts "\nadding recipes:\n  #{added_craftbot.map { |r| r["itemId"] }.join "\n"}"
  new_craftbot = (current_craftbot + added_craftbot).uniq { |r| r["itemId"] }

  puts "\nadding item names:\n  #{added_item_names}"
  new_item_names = current_item_names.merge added_item_names

  puts "\nadding inventory descriptions:\n  #{added_inventory_descriptions}"
  new_inventory_descriptions = current_inventory_descriptions.merge added_inventory_descriptions

  puts "\ncopying icon map"
  write_file CurrentSurvivalIconMap, File.read("Survival/Gui/IconMapSurvival.xml")
end

write_file current_craftbot_file, new_craftbot.to_json
write_file current_item_names_file, new_item_names.to_json
write_file current_inventory_descriptions_file, new_inventory_descriptions.to_json
write_file current_shape_set_entries_file, { "shapeSetList" => new_shape_set_entries }.to_json