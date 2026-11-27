foreach name, dep : {
  'util_queue_finish' : idep_mesautil,
  'nir_object_ids' : idep_nir,
}
  regression = executable(
    name,
    files(name + '.c'),
    dependencies : dep,
    build_by_default : false,
  )
  test(name, regression, suite : 'steamac', timeout : 0)
endforeach
