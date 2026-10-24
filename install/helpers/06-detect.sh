#!/bin/bash
helpers::is_vm() {
  [[ "$CHASSIS_TYPE" == vm ]]
}
