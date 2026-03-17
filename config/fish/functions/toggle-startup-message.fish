# @vibranium
function toggle-startup-message --description "Toggle startup greeting message"
  if not test -f $XDG_CONFIG_HOME/fish/states/silent
    touch $XDG_CONFIG_HOME/fish/states/silent
    echo "Startup message disabled"
  else
    rm -f $XDG_CONFIG_HOME/fish/states/silent
    echo "Startup message enabled"
  end
end
