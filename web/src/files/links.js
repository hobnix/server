// Links that open Storage > Files pre-filled (pages/Files.svelte reads them): left/right = location ids (disk:data-04, pool:bulk, share:media),
// path/rpath = the folder in the left/right pane, select = a name to select in the left pane.
//   go(filesLink({ left: 'disk:data-04', path: '/shares/media', right: 'disk:data-01' }))
export const filesLink = (o) => `/storage/files?${new URLSearchParams(Object.entries(o).filter(([, v]) => v)).toString()}`;
